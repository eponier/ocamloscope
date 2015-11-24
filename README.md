Installation
===========================

Required softwares
---------------------------

* OCaml 4.02.3 (Code is highly dependent on the specific compiler version. Do not try compiling with other versions.)
* OPAM >= 1.2, findlib and OMake to build.
* spotlib >= 2.5.2
* ppx_meta_conv >= 2.2
* ppx_orakuda >= 2.0.0
* treeprint >= 2.0.0 (2.1 is better, avoid the hack below)
* levenshtein >= 1.1.0
* ppx_test >= 1.2.1
* ocsigenserver >= 2.6
* eliom >= 4.2.0

Windows is not supported.

OPAM package for OCamlOScope is not yet available... since it requires the following mending of external softwares.

Missing `cmxs` files
---------------------------

Some of the above packages lack `cmxs` files and you have to build them manually to run the native build of OCamlOScope on Ocsigen. This is not needed at all if you use only bytecode.

### `ocamlcommon.cmxs` is missing in OCaml 4.02.1.

The following should create `ocamlcommon.cmxs`:

```shell
$ DIR=`ocamlc -where`
$ cd $DIR
$ ocamlopt -linkall -shared compiler-libs/ocamlcommon.cmxa -o compiler-libs/ocamlcommon.cmxs
```

However, I find it stopped working in recent Mac OS X. It required the following fixes:

* Build `ocamlcommon2.cmxa` just like as `ocamlcommn.cmxa` but link with `byterun/prims.o`, `-lccopt byterun/libcamlrun_shared.so` and `-ccopt -lcurses`.
* Then create `ocamlcommon.cmxs` from this `ocamlcommon2.cmxa`.

It seems due to Clang and its use in OCaml compiler build, but I do not understand why it requires.

### `odoc_info.cmxs` is missing in OCaml 4.02.1.

The following command should create `odoc_info.cmxs`:

```shell
$ ocamlopt -linkall -shared ocamldoc/odoc_info.cmxa -o ocamldoc/odoc_info.cmxs
```

How to build
---------------------------

```shell
$ cp OMakeroot.in OMakeroot
$ omake
```

How to build DB
---------------------------

What does scraping need:

* `cmt` files. OCaml modules must be compiled with `OCAMLPARAM=_,bin-annot=1`, and the compiled source tree with `cmt` files must be kept.
* For softwares installed by OPAM, `OPAMKEEPBUILDDIR=yes` is required to keep ths source files

The following command should scrape the OCaml compiler source code and all the installed OCamlFind libraries and their corresponding OPAM build directorires, and stores the result under `data/` directory.

```shell
$ ./oco -d -c <ocaml compiler source dir>
```

NB: I do not really understand what is `<ocaml compiler source dir>` and why it is needed (indeed, if the switch is installed with the two flags given above, there is a directory `ocaml` in `build`).

How to query locally
---------------------------

After scraping, `oco` goes to its console query mode against the dumped data file.

How to start Eliom server
---------------------------------

Change directory to `eliom/`, copy `eliom/oco.conf.in` to `oco.conf` and change `@PORT@` and `@OCAMLLIB@`. You must also create a file called `oco_conf.ml` containing something of the form `{ocamlc_source_dir = "<ocaml compiler source dir>"}`. I assume that this parameter is the same as the one used in the command line above.

```shell
$ ./starteliom.sh
```
