open Spotlib.Spot
open List
open Orakuda.Regexp.Infix

let () = Lexer.init () (* We need this ... *)

module Query = struct
  type t = 
      { kind  : Kindkey.search option;
        path  : Spath.t option;
        type_ : Stype.t option;
        dist0 : bool;
      }

  let to_string { kind= k;
                  path= popt;
                  type_= tyopt;
                  dist0;
                } =
    begin if dist0 then "exact " else "" end
    ^
    begin match k with
    | None -> "*"
    | Some k -> Kindkey.to_string k
    end ^ " " ^
    begin match popt with
    | None -> "*"
    | Some p -> Spath.show p
    end ^ " : " ^
    begin match tyopt with
    | None -> "_"
    | Some ty -> Stype.to_string ty
    end

  module Parse = struct
    (* CR jfuruse: it does not parse _, M._ or M._.x *)
    (* CR jfuruse: it does not parse Make : _  (make : _ works) *)
    let path str =
      let path str = 
        try
          let sitem = 
            Lexing.from_string str
            |> XParser.pattern_longident Lexer.token
            |> Spath.of_longident
          in 
          Some { kind = None; path= Some sitem; type_= None; dist0= false; }
        with
        | _ -> (* !!% "failed to parse as a path %S@." str; *) None
      in
      let open Option in
      path str >>=! fun () -> path ("(" ^ str ^ ")") 
  
    let type_ s = 
      let open Option in
      Util.Result.to_option (Stype_print.read s) >>= fun ty ->
      return { kind = None; path = None; type_= Some ty; dist0= false; }
  
    let path_type str =
      try
        let pos = String.index str ':' in
        let p = String.sub str 0 pos in
        let t = String.sub str (pos+1) (String.length str - pos - 1) in
        let p = path p in
        let t = type_ t in
        match p, t with
        | None, _ | _, None -> None
        | Some p, Some t ->
            Some { kind= None; path= p.path; type_= t.type_; dist0= false; }
  (*
        | Some {path = Some Lident ("_" | "_*_")}, 
          Some {type_ = Some { ptyp_desc= Ptyp_any }} -> 
            (* Funny *)
  *)
      with
      | _ -> None
  
    let prefixed str =
      let open Option.Open in
      try
        (* CR jfuruse: parsing of kind is very ugly *)
        (str =~ <:m<(class|class\s+val|class\s+type|constr|exception|field|method|module|module\s+type|type|val|package)\s+>>) >>= fun res ->
        Kindkey.of_string res#_1 >>= fun k ->
        path res#_right >>= fun p ->
        return { kind=Some k; path=p.path; type_= None; dist0= false; }
      with
      | _ -> None
  
    let prefixed_and_type str =
      let open Option.Open in
      try
        (* CR jfuruse: parsing of kind is very ugly *)
        (str =~ <:m<(class\s+val|constr|exception|field|method|val)\s+>>) >>= fun res ->
        Kindkey.of_string res#_1 >>= fun k -> 
        path_type res#_right >>= fun res ->
        return { res with kind = Some k }
      with
      | _ -> None
  
    let query s = 
      let s = <:s<(^\s+|\s+$)//g>> s in
      match s with
      | "" -> None
      | _ ->
          let exact, s =
            if s.[0] = '!' then true, String.drop 1 s
            else false, s
          in
          let wrap q = { q with dist0 = exact } in
          Some (map wrap & filter_map id
                  [ path_type s ; path s ; type_ s; prefixed s; prefixed_and_type s ])
  
  end

  let parse = Parse.query
end

open Query

(** Search result is grouped by the lookings of items *)

type look = int * Spath.t * string option

let look_of_item i =
  let open Stype in
  let open Item in
  (* kind string affects the order of search results *)
  let int_of_kind x = 
    match x with
    | Item.Value _ -> 0
    | Type _ ->       10
    | Exception _ ->  20
    | Class ->        25
    | Module ->       30
    | Package _ ->    35
    | ClassType ->    40
    | ModType ->      50
    | Method _ ->     60
    | Constr _ ->     70
    | Field _ ->      80
    | ClassField _ -> 90
  in 
  let path = Spath.short_look i.Item.path in
  let kind = 
    match i.kind with
    | (Class | ClassType | ModType | Module | Package _ as k) -> k
    | Type (xtyps, Some xtyp, x) -> 
        begin match short_look (Tuple (xtyp :: xtyps)) with
        | Tuple (xtyp :: xtyps) -> Type (xtyps, Some xtyp, x)
        | _ -> assert false
        end
    | Type (xtyps, None, x) ->
        begin match short_look (Tuple xtyps) with
        | Tuple xtyps -> Type (xtyps, None, x)
        | _ -> assert false
        end
    | ClassField (x, xty) -> ClassField (x, short_look xty)
    | Constr xty -> Constr (short_look xty)  
    | Exception xty -> Exception (short_look xty)
    | Field xty -> Field (short_look xty)   
    | Value xty -> Value (short_look xty)   
    | Method (x, y, xty) -> Method (x, y, short_look xty)
  in
  let xtyopt = match kind with
    | Item.Class | ClassType | ModType | Module | Package _ -> None

    (* CR jfuruse: bizarre encoding *)
    | Type (xtyps, Some xtyp, _) -> Some (Arrow ("", Tuple xtyps, xtyp))
    | Type (xtyps, None, _) -> Some (Tuple xtyps)

    | ClassField (_, xty)
    | Constr xty   
    | Exception xty 
    | Field xty    
    | Value xty    
    | Method (_, _, xty) -> Some xty
  in
  { i with path; kind },
  (int_of_kind i.kind, 
   path,  
   Option.map Stype.to_string xtyopt : look)

let look_length = function
  | (_, _, None) -> 0
  | (_, _, Some s) -> String.length s

module QueryResult = struct
  type t = 
    [ `EmptyQuery
    | `Error
    | `Funny
    | `Ok of Query.t list 
             * (int (** dist *) 
                * (Item.t (** short look *) * int (** look_length *)
                   * (OCamlFind.Packages.t * (int * Item.t) list) list)
               ) list
             * float * float (** times *)
             * int (** size = number of items *) 
    ]

  let size = function
    | `EmptyQuery | `Error | `Funny -> 1
    | `Ok (_, _, _, _, size) -> size
end

type trace = [ `Nope
             | `Path of Spath.t
             | `PathType of Spath.t * Stype.t
             | `Type of Stype.t ]

let enrich_with_trace item (trace : trace) =
  let path = match trace with
    | `Nope | `Type _ -> item.Item.path
    | `Path p | `PathType (p, _) -> p
  in
  let kind = match trace with
    | `Nope | `Path _ -> item.Item.kind
    | `Type ty | `PathType (_, ty) -> 
       match item.Item.kind with
       | ClassField (vf, _) -> ClassField (vf, ty)
       | Constr _           -> Constr ty
       | Exception _        -> Exception ty
       | Field _            -> Field ty
       | Method (pf, vf, _) -> Method (pf, vf, ty)
       | Value _            -> Value ty
       | _ -> assert false
  in
  { item with Item.path; kind }

(** Rough textual length of Spath.t. (+) is counted as 1 *)
let spath_len = 
  let rec len = function 
    | Spath.SPdot (SPpredef, s) -> String.length s
    | SPident id -> String.length id
    | SPdot (p, name) -> len p + String.length name + 1
    | SPapply (p1, p2) -> len p1 + len p2 + 3
    | SPpack pks -> 2 + String.length (OCamlFind.Packages.to_string_for_printing pks)
    | SPpredef -> 0
    | SPattr (_, t) -> len t
  in
  len

let sort_by f xs =
  map (fun x -> (x, f x)) xs
    |> sort (fun (_,l1) (_,l2) -> compare l1 l2)
    |> map fst

(** Group items by their looks. Traces are used for enrich the items. *)
let group_by_look 
    : (int * Item.t * trace) list 
    -> (Item.t (** short_look *) * int (** look_length *) * (int * Item.t) list) list =
  map (fun (n, i, trace) ->
    let i = enrich_with_trace i trace in
    (n, i, look_of_item i))
  *> 
    sort_then_group (fun (_,_,(_,l1)) (_,_,(_,l2)) -> compare l1 l2)
  *> 
    map (fun g -> 
      let (_, _, (i,l)) = hd g in
      i, look_length l,
      map (fun (id,i,_) -> (id,i)) g)

(** Group items by packages *)
let group_by_package 
    : (int * Item.t) list 
      -> (OCamlFind.Packages.t * (int * Item.t) list) list =
  sort_then_group (fun (_, i1) (_, i2) -> 
    OCamlFind.Packages.compare i1.Item.packs i2.packs)
  *>
    map (fun iis ->
      let (_, i) = hd iis in
      i.Item.packs, 
      sort_by (fun (_, item) -> spath_len item.Item.path) iis)

(** Sort look group by popularity *)
let sort_looks_by_popularity 
    : ('a1 * int (** look_length *) * (OCamlFind.Packages.t * 'a2 list) list) list
    -> ('a1 * int (** look_length *) * (OCamlFind.Packages.t * 'a2 list) list) list = 
  sort_by (fun (_, look_length, p_s) ->
    let score = sum & map (fun (p, xs) ->
      match OCamlFind.Packages.to_strings p with
      | [ "stdlib" ] -> length xs * 100
      | _ -> length xs) p_s
    in
    -. float score /. (float (look_length + 1)))

let group_results = 
  group_by_look 
  *> map (fun (i, len, xs) -> (i, len, group_by_package xs))
  *> sort_looks_by_popularity

let query items qs = 
  let module M = struct
    module Match = Match.Make(struct
      let cache = Levenshtein.StringWithHashtbl.create_cache 1023
    end)
    
    let query_item max_dist {kind= k_opt; path= lident_opt; type_= qtyp_opt; dist0 } i = 
      let max_dist = if dist0 then 0 else max_dist in
      match i.Item.kind with
      (* Items without types *)
      | Item.Class 
      | ClassType
      | ModType
      | Module
      | Type _ 
      | Package _ ->
          begin match k_opt, i.Item.kind with
            | (None | Some `Class), Class 
            | (None | Some `ModType), ModType
            | (None | Some `Module), Module
            | (None | Some `Type), Type _
            | (None | Some `ClassType), ClassType
            | (None | Some `Package), Package _ ->
                begin match lident_opt, qtyp_opt with
                | None, None -> Some (10, `Nope)
                | Some lid, None -> 
                    Option.map (fun (s, d) -> (s, `Path d)) & Match.match_path lid i.path (min max_dist 10)
                | _, Some _ -> None
                end
            | Some `ExactPackage, Package _ ->
                begin match lident_opt, qtyp_opt with
                | None, None -> None
                | Some lid, None -> 
                    Option.map (fun (s, d) -> (s, `Path d)) & Match.match_path lid i.path 0 (* exact match *)
                | _, Some _ -> None
                end
            | _ -> None
          end
            
      (* Items with types *)
      | ClassField _
      | Constr _
      | Exception _
      | Field _
      | Method _
      | Value _ -> 
          begin match k_opt, i.kind with
          | (None | Some `ClassField) , ClassField (_, typ)
          | (None | Some `Constr    ) , Constr typ
          | (None | Some `Exception ) , Exception typ
          | (None | Some `Field     ) , Field typ
          | (None | Some `Method    ) , Method (_, _, typ)
          | (None | Some `Value     ) , Value typ ->
              begin match lident_opt, qtyp_opt with
              | None, None -> Some (10, `Nope)
              | Some lid, None -> Option.map (fun (s, d) -> s, `Path d) & Match.match_path lid i.path (min max_dist 10)
              | None, Some qtyp -> Option.map (fun (s, d) -> s, `Type d) & Match.match_type qtyp typ max_dist 
              | Some lid, Some qtyp ->
                  Option.map (fun (s, ds) -> s, `PathType ds) & Match.match_path_type (lid,qtyp) (i.path,typ) (min max_dist 10) max_dist 
              end
          | _ -> None
          end
            
    let query_item max_dist q i = 
      query_item max_dist q i
      |- fun _ -> 
        if !Match.error then
          !!% "ERROR happened at match of %a@." Item.format i
      
    let query items qs =
      let funny = function
        | { kind=_; path=None; type_=None } -> true
        | _ -> false
      in
    
      match qs with
      | None -> `EmptyQuery
      | Some [] -> `Error
      | Some qs when for_all funny qs -> `Funny
      | Some qs ->
          let qs = filter (not *< funny) qs in
    
          let found, search_time = flip Unix.timed () & fun () ->
            Array.foldi_left 
              (fun st i item ->
                let thresh = Distthresh.thresh st in
                let res =
                  fold_left (fun st q ->
                    (* If one q succeeds then we can cull the limit for the other qs *)
                    let thresh = match st with
                      | None -> min thresh 30
                      | Some (s, _) -> min thresh (s - 1)
                    in
                    match query_item thresh q item with
                    | None -> st
                    | (Some _ as res) -> res) None qs
                in
                match res with
                | Some (dist, d) -> Distthresh.add st dist (i, item, d)
                | None -> st) 
              (Distthresh.create ~thresh:30 ~limit:200) 
              items
          in
          let (final_result, size), group_time = flip Unix.timed () & fun () ->
            let found = Distthresh.to_list found in
            let size = map (fun (_, xs) -> length xs) found |> sum in
            let group_scored_items (score, id_item_descs) = 
              map (fun g -> (score,g)) & group_results id_item_descs 
            in
            TR.concat_map group_scored_items found, size
          in
    
          `Ok (qs, final_result, search_time, group_time, size)
  end in
  M.query items qs |- fun _ -> M.Match.report_prof_type ()

let search items query_string : QueryResult.t = 
  query items & Query.parse query_string

let textual_query items query_string =
  let (!!%) = Format.printf in
  match search items query_string with
  | `Ok (_qs, res, search_time, group_time, _size) -> 
      !!% "%f secs (search: %f, group: %f)@." (search_time +. group_time) search_time group_time;
      flip iter res (fun (score, (short_look, _, xs)) -> 
        !!% "%d : @[%a@]@.@." 
          score 
          (Item.format_gen ~dont_omit_opened:true) short_look;
          
        flip iter xs (fun (pkgs, iis) ->
          !!% "  Packages: %s@." 
            (String.concat ", " (OCamlFind.Packages.to_strings pkgs));
          iter (fun (_,i) ->
            !!% "    @[<2>%a@]@." Item.format i) iis;
          !!% "@."))
  | `Error -> !!% "The input could not be parsed as a query@."
  | `Funny -> !!% "Hahaha! You are so funny. _:_@."
  | `EmptyQuery -> ()

let rec cui items =
  print_string "? "; 
  flush stdout;
  textual_query items & read_line ();
  cui items

let cli () =
  if Conf.dump then Load.dump_items (); 

  if not Conf.dump && Conf.args <> [] then failwith "ERROR: Only dump (-d) mode can take args without flags";

  let { Load.items } = Load.load_items () in

  let module M = Tests.Do(struct let items = items end) in

  if Conf.show_stat then begin 
    Stat.report items; exit 0 
  end;
    
  cui items

