open Spotlib.Spot
open List

open Stype
module I = Ident

module Make( A: sig

  val cache : Levenshtein.StringWithHashtbl.cache

end) = struct

  let error = ref false

  module Make(A : sig
    type t (* distance *)
    val zero : t
    val plus : t -> t -> t
    val minus : t -> t -> t option
    val one_less : t -> t option
  end) = struct

    open A

    let with_penalty n f limit0 = Option.do_;
      limit <-- minus limit0 n;
      (dist, x) <-- f limit;
      return (plus dist n, x)

    let (/||/) f1 f2 limit0 =
      match f1 limit0 with
      | None -> f2 limit0
      | (Some (dist, _) as res) -> Option.do_; 
          limit <--minus limit0 dist;
          limit <-- one_less limit;
          match f2 limit with
          | None -> res
          | res -> res

    let (/&&/) f1 f2 limit0 = Option.do_;
      (dist, x) <-- f1 limit0;
      limit <-- minus limit0 dist;
      (dist',x') <-- f2 limit;
      return (plus dist dist', (x,x'))

    let (>>) g f = fun limit -> Option.do_;
      (dist, x) <-- g limit;
      return (dist, f x)

    let fail _ = None

    let return v = fun _ -> Some (zero, v)
  end

  module Int = Make(struct
    type t = int
    let zero = 0
    let plus = (+)
    let minus limit n = 
      let x = limit - n in 
      if x < 0 then None else Some x
    let one_less x = if x <= 0 then None else Some (x-1)
  end)

  module TypeLimit = struct
    module A  = struct
      type t = { score: int; expansions: int; }

      let zero = { score = 0; expansions = 0 }

      let plus m n = { score      = m.score + n.score
                     ; expansions = m.expansions + n.expansions }

      let one_less m = 
        if m.score <= 0 then None 
        else Some { m with score = m.score - 1 }

      let minus limit n =
        let score' = limit.score - n.score in
        let expansions' = limit.expansions - n.expansions in
        if score' < 0 || expansions' < 0 then None
        else Some { score = score'; expansions = expansions' } 

      let create score = { score; expansions = 50 }
  (* Type alias expansion is limited to 50. CR jfuruse: make it configurable. *)
    end
    include A
    include Make(A)
  end

  let is_operator = function
    | "" -> false
    | s ->
        match s.[0] with
        | 'A'..'Z' | 'a'..'z' | '_' | '0'..'9' | '#' (* class type *) -> false
        | _ -> true

  let match_name_levenshtein
      : string  (** pattern *)
      -> string (** target *)
      -> int    (** limit (upperbound) *)
      -> (int (** distance. Always <= limit *)
          * (string (** the matched *) 
             * string option(** the corresponding pattern. This is always Some but it is intentional *)
         )) option
  = fun n m ->
    let n0 = n in
    let m0 = m in
    let open Int in
    match n with
    | "_" | "_*_" -> return (m0, Some n0)
    | "(_)" when is_operator m -> return (m, Some n)
    | _ -> 
        if n = m then return (m0, Some n0)
        else
          fun limit ->
            let n = String.lowercase n
            and m = String.lowercase m in
            let dist = 
              match Levenshtein.StringWithHashtbl.distance A.cache ~upper_bound:limit n m with
              | Levenshtein.Exact n -> n
              | GEQ n -> n
            in
            if dist > limit then None
            else Some (dist, (m0, Some n0))
            
  let match_name_substring 
      : string  (** pattern *)
      -> string (** target *)
      -> (int * (string (** the matched *) 
                 * string option(** the corresponding pattern. This is always Some but it is intentional *)
         )) option
  = fun n m ->
    let n0 = n in
    let m0 = m in
    match n with
    | "_" | "_*_" -> Some (0, (m0, Some n0))
    | "(_)" when is_operator m -> Some (0, (m, Some n0))
    | _ -> 
        if n = m then Some (0, (m0, Some n0))
        else
          let fix s =
            let len = String.length s in
            let b = Buffer.create len in
            for i = 0 to len-1 do
              match String.unsafe_get s i with
              | '_' -> ()
              | c -> Buffer.add_char b & Char.lowercase c
            done;
            Buffer.contents b
          in
          let n = fix n
          and m = fix m in
          if not (String.is_substring ~needle:n m) then None
          else 
            let dist = String.length m - String.length n in
            (* CR jfuruse: We can return something more fancy like Hoogle *)
            Some (dist, (m0, Some n0))

  let match_name p t limit = match false with
    | true  -> match_name_levenshtein p t limit
    | false -> Option.do_;
        [%p? (dist, _) as r] <-- match_name_substring p t;
        if dist <= limit then return r else None

  let match_package 
      : string (* pattern *)
      -> OCamlFind.Packages.t (* target *)
      -> int (* limit (upperbound) *)
      -> (int * (OCamlFind.Packages.t (* the matched *)
                 * (string * string option) (* string match info *))) option
  = fun n phack ->
    let open Int in
    let ps = OCamlFind.Packages.to_strings phack in
    let matches = 
      List.map (fun p -> match_name n p >> fun d -> (phack, d)) ps
    in
    fold_left1 (/||/) matches

  let rec match_path pat p =
    let open Int in
    let open Spath in
    match pat, p with
    | SPdot(n1, "_*_"), SPdot(m1, m2) -> 
        match_path n1 m1 /||/ match_path pat m1
        >> fun d1 -> nhc_dot d1 m2
    | SPident n,   SPpack phack ->
        match_package n phack 
        >> fun d -> nhc_attr (`Pack (pat, d)) p
    | SPident n,   SPdot(_m1, m2) ->
        match_name n m2
        >> fun d2 -> nhc_attr (`AfterDot d2) p
    | SPident n,   SPident m ->
        match_name n m
        >> fun d -> nhc_attr (`Ident (pat, d)) p
    | SPdot(n1, n2), SPdot(m1, m2) ->
        match_name n2 m2 /&&/ match_path n1 m1
        >> fun (d2,d1) -> nhc_attr (`AfterDot d2) (nhc_dot d1 m2)
    | SPapply (li1, _li2), SPapply (p1, p2) ->
        (* A(B) matches with A(C) *)
        (* CR jfuruse: li2 is given but never used... *)
        match_path li1 p1 
        >> fun d -> nhc_apply d p2
    | li, SPapply (p1, p2) ->
        (* A matches with A(C) but with slight penalty *)
        with_penalty 1 & match_path li p1 >> fun d -> nhc_apply d p2
    | _ -> fail
  
  let dummy_pattern_type_var = Any
  let dummy_type_expr_var = Var (-1)

  let hist_type = ref []

  let prof_type pat targ =
    if Conf.prof_match_types then
      try 
        let xs = assq pat !hist_type in
        try 
          let r = assq targ !xs in
          incr r
        with
        | Not_found ->
            xs := (targ, ref 1) :: !xs
      with
      | Not_found ->
          hist_type := (pat, ref [(targ, ref 1)]) :: !hist_type
    
  let report_prof_type () =
    if Conf.prof_match_types then
      let distinct, total = 
        fold_left (fun st (_, xs) ->
          fold_left (fun (d,t) (_, r) -> (d+1, t + !r)) st !xs) (0,0) !hist_type
      in
      !!% "distinct=%d total=%d@." distinct total

  (* I never see good result with no_target_type_instantiate=false *)
  let match_type (* ?(no_target_type_instantiate=true) *) pattern target limit 
      : (TypeLimit.t * _) option
      =
    prof_type pattern target;
    let open TypeLimit in

    (* We try to remember matches like 'a = 'var. 
       If we see a match 'a = 'var2 later, we lower the limit slightly
       in order to give 'a = 'var higher score
       
       CRv2 jfuruse: We can extend this to var to non var type case,
       since stype is hcons-ed.  Ah, but we have subtyping...
    *)
    let var_match_history = Hashtbl.create 107 in

    let rec match_type pattern target =
      let open TypeLimit in
      (* pattern = tvar is treated specially since it always returns the maximum score w/o changing the pattern *)
      match pattern, target with
      | (Var _ | Univar _ | UnivarNamed _), _ -> assert false 
      | VarNamed (_, s), (Var _ | VarNamed _ | Univar _ | UnivarNamed _) -> 
          begin match Hashtbl.find_opt var_match_history s with
          | None -> 
              Hashtbl.add var_match_history s (`Found target); 
              return (Attr (`Ref pattern, target))
          | Some (`Found target') when target == target' -> 
              return (Attr (`Ref pattern, target))
          | Some (`Found _) ->
              (* A variable matches with different types 
                 We mark this fact so that limit is lowered at most one time 
                 for one variable.
              *)
              Hashtbl.replace var_match_history s `Unmatched;
              with_penalty { score= 1; expansions= 0 } & return (Attr (`Ref pattern, target))
          | Some `Unmatched -> 
              return (Attr (`Ref pattern, target))
          end
          
      | Any, (Var _ | VarNamed _ | Univar _ | UnivarNamed _) -> 
          (* return (limit, Attr (`Ref pattern, target)) *)
          (* Any is used for dummy pattern vars in match_types, so it should not be highlighted *)
          return target

      | Any, _ -> 
          (* Any matches anything but with a slight penalty. No real unification. *)
          with_penalty { score= 1; expansions= 0 } & return (Attr (`Ref pattern, target))
    
      | _, Link { contents = `Linked ty } -> 
          with_penalty { score= 1; expansions= 0 } & match_type pattern ty
  
      | _, Link _ -> fail
      | _ ->
    
          fold_left1 (/||/) [
            remove_target_type_option pattern target;
            make_tuple_left  pattern target;
            make_tuple_right pattern target;
            match_arrow_types pattern target;
  
            match_alias pattern target;
  
            (match pattern, target with
    
            | Tuple ts1, Tuple ts2 -> 
                match_types ts1 ts2 
                >> fun ds -> Attr (`Ref pattern, Tuple ds)
    
            | Constr ({dt_path=p1}, ts1), Constr (({dt_path=p2} as dt), ts2) -> 
                ((fun limit -> Option.do_;
                    (dist, pd0) <-- match_path p1 p2 limit.score;
                    return ({score=dist; expansions=0}, pd0))
                 /&&/ match_types ts1 ts2 )
                >> fun (pd,ds) -> Attr (`Ref pattern, Constr ({dt with dt_path= pd}, ds))
  
            | _, (Var _ | VarNamed _ | Univar _ | UnivarNamed _) ->
                with_penalty { score=1000; expansions= 0 } 
                & return (Attr (`Ref pattern ,target))
                (* CR jfuruse: it is just fail?! *)
    
            | _ -> fail)
          ]
    
    and match_alias pattern target limit =
      if limit.expansions <= 0 then None
      else
        let limit = { limit with expansions = limit.expansions - 1 } in
        (match target with
        | Constr ({dt_path= _p; dt_aliases= {contents = Some (Some (params, ty))}}, ts2) ->
            if length params <> length ts2 then begin
              !!% "@[<2>ERROR: aliased type arity mismatch:@ %a@ (where alias = (%a).%a)@]@."
                Stype.format target
                Format.(list ", " Stype.format) params
                Stype.format ty;
              error := true;
              fail
            end else
              match_type pattern (Stype.subst params ts2 ty) 
              >> fun d -> Attr(`Ref pattern, d)
        | _ -> fail) limit
  
    and match_arrow_types pattern target =
      let parrows, preturn = get_arrows pattern in
      let tarrows, treturn = get_arrows target in
      match parrows, tarrows with
      | [], [] -> fail (* avoid inf loop *)
      | _ ->
          (match_type preturn treturn 
           /&&/ match_types (map snd parrows) (map snd tarrows))
          >> fun (dret, dts) -> 
            fold_right (fun (l,t) st -> Arrow (l, t, st)) 
              (combine (map fst tarrows) dts)
              dret
    
    and remove_target_type_option pattern target =
      match target with
      | Constr ( ({ dt_path=Spath.SPdot (Spath.SPpredef, "option") } as dt),
                 [t2]) ->
          with_penalty { score= 10; expansions= 0 } (* CR jfuruse: 10 is too big? *)
          & match_type pattern t2 
            >> fun d -> Constr (dt, [d])
      | _ -> fail
    
    and make_tuple_left pattern target =
      match pattern, target with
      | _, Tuple ts2 -> 
          match_types [pattern] ts2
          >> fun ds -> Tuple ds
      | _ -> fail
    
    and make_tuple_right pattern target =
      match pattern, target with
      | Tuple ts1, _ -> 
          match_types ts1 [target] 
          >> (function 
            | [d] -> d
            | _ -> assert false)
      | _ -> fail
    
    and match_types pats targets =
      (* matching of two list of types, with permutation and addition/removal *)
    
      match pats, targets with
      | [], [] -> return []
      | [pat], [target] ->  match_type pat target >> fun d -> [d]
      | _ -> fun (limit : TypeLimit.t) ->

          let len_pats = length pats in
          let len_targets = length targets in
    
          let pats, targets, penalty =
            (* Some component might be missing in pattern, we fill variables for them
               but with a rather big price

               At 8a9d320d4 :
                   pattern: int -> int -> int -> int
                   target:  nat -> int -> int -> nat -> int -> int -> int
                   distance = 12 = 3 * (addition(3) + instance(1))

               I think 2 arguments addition is enough
                   2 * (addition(x) + 1) < 30
               how about 7? (2*(7+1)=16 3*(7+1)=24<30 4(7+1)=32>30 
            *)
            if len_pats < len_targets then
              ( XSpotlib.List.create (len_targets - len_pats) (fun _ -> dummy_pattern_type_var) @ pats,
                map (fun target -> target, true) targets,
                (len_targets - len_pats) * 7 )
            else if len_pats > len_targets then
              (* The target can have less components than the pattern,
                 but with huge penalty

                 At 8a9d320d4 : x5
                 changed to     x10
              *)
              ( pats,
                XSpotlib.List.create (len_pats - len_targets) (fun _ ->
                  (dummy_type_expr_var, false))
                @ map (fun target -> target, true) targets,
                (len_pats - len_targets) * 10 )
            else pats, map (fun x -> (x, true)) targets, 0
          in

          (* redefine limit with the penalty of missing components *)
(*
          Option.do_;
          limit <-- TypeLimit.minus limit { score= penalty; expansions = 0 };
*)
          Option.bind (TypeLimit.minus limit { score= penalty; expansions = 0 }) & fun limit ->

          (* If we do things naively, it is O(n^2).
             I've got [GtkEnums._get_tables : unit -> t1 * .. * t70].
             Its permutation is ... huge: 1.19e+100.
           *)
    
          let targets_array = Array.of_list (map fst targets) in
          let score_table =
            (* I believe laziness does not help here *)
            flip map pats & fun pat ->
              flip Array.map targets_array & fun target -> 
                match_type pat target limit
          in
    
          let rec perm_max target_pos xs limit : (TypeLimit.t * _) option = match xs with
            | [] -> Some (TypeLimit.zero, [])
            | _ ->
                (* [choose [] xs = [ (x, xs - x) | x <- xs ] *)
                let rec choose sx = function
                  | [] -> assert false
                  | [x] -> [x, rev sx]
                  | x::xs -> (x, rev_append sx xs) :: choose (x::sx) xs
                in
                let xxss = choose [] xs in

                let f x xs limit = Option.do_;
                  (* CR jfuruse: the logic is /&&/ *)
                  (dist, d) <-- Array.unsafe_get x target_pos;
                  limit <-- TypeLimit.minus limit dist;
                  (dist, ds) <-- perm_max (target_pos+1) xs limit;
                  return (dist, d::ds)
                in
                
                fold_left1 (/||/) (map (fun (x,xs) -> f x xs) xxss) limit
          in
          Option.do_;
          (dist, ds) <-- perm_max 0 score_table limit;
          (* remove dummy variable match traces from the result *)
          return & (dist, flip filter_map (combine ds targets)
                          & function
                            | (_, (_, false)) -> None
                            | (d, (_, true)) -> Some d)
    in
    
    match_type pattern target limit
  
  (* Return distance, not score *)
  let match_path_type (p1, ty1) (p2, ty2) limit = Option.do_;
    (dist_path, match_path) <-- match_path p1 p2 limit;
    let limit = TypeLimit.create (limit - dist_path) in
    (dist_type, match_xty) <-- match_type ty1 ty2 limit;
    return (dist_path + dist_type.TypeLimit.score, (match_path, match_xty))
    
  
  (* Return distance, not score *)
  let match_type (* ?no_target_type_instantiate *) t1 t2 limit_type = Option.do_;
    (dist, desc) <-- match_type (* ?no_target_type_instantiate *) t1 t2 (TypeLimit.create limit_type);
    return (dist.TypeLimit.score, desc)
  
end 




module MakePooled( A: sig

  val cache : Levenshtein.StringWithHashtbl.cache
  val pooled_types : Stype.t array

end) = struct

  module M = Make(A)

  let error = M.error

  let match_path = M.match_path

  module WithType(T : sig
    val pattern : Stype.t
    val cache : [ `NotFoundWith of int | `Exact of int * Stype.t ] array
  end) = struct

    let match_type t2 limit_type =
      let t1 = T.pattern in
      match t2 with
      | Item.Not_pooled t2 -> M.match_type t1 t2 limit_type
      | Item.Pooled n ->
          let t2 = Array.unsafe_get A.pooled_types n in
          match Array.unsafe_get T.cache n with
          | `NotFoundWith n when n >= limit_type -> None
          | _ ->
              match M.match_type t1 t2 limit_type with
              | None -> 
                  Array.unsafe_set T.cache n (`NotFoundWith limit_type);
                  None
              | Some dtrace as res ->
                  Array.unsafe_set T.cache n (`Exact dtrace);
                  res
    
    let match_path_type p1 (p2, ty2) limit = Option.do_;
      (dist_path, match_path) <-- match_path p1 p2 limit;
      (dist_type, match_xty) <-- match_type ty2 (limit - dist_path);
      return (dist_path + dist_type, (match_path, match_xty))

  end
  
  let report_prof_type = M.report_prof_type
end 
