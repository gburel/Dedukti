open Basic
open Term
open Rule
open Parser

let out = ref stdout
let deps = ref []
let md_to_file = ref []
let filename = ref ""
let verbose = ref false
let sorted = ref false

let print_out fmt = Printf.kfprintf (fun _ -> output_string !out "\n" ) !out fmt

(* This is similar to the function with the same name in
   kernel/signature.ml but this one answers wether the file exists and
   does not actually open the file *)
let rec find_dko_in_path name = function
  | [] -> false
  | dir :: path ->
      let filename = dir ^ "/" ^ name ^ ".dko" in
        if Sys.file_exists filename then
          true
        else
          find_dko_in_path name path

(* If the file for module m is not found in load path, add it to the
   list of dependencies *)
let add_dep m =
  let s = string_of_mident m in
  if not (find_dko_in_path s (get_path()))
  then begin
      let (name,m_deps) = List.hd !deps in
      if List.mem s (name :: m_deps) then ()
      else deps := (name, List.sort compare (s :: m_deps))::(List.tl !deps)
  end

let init md =
  let name = string_of_mident md in
  deps := (name, [])::!deps


let rec mk_term = function
  | Kind | Type _ | DB _ -> ()
  | Const (_,cst) -> add_dep (md cst)
  | App (f,a,args) -> List.iter mk_term (f::a::args)
  | Lam (_,_,None,te) -> mk_term te
  | Lam (_,_,Some a,b)
  | Pi (_,_,a,b) -> ( mk_term a; mk_term b )


let rec mk_pattern = function
  | Var  (_,_,_,args) -> List.iter mk_pattern args
  | Pattern (_,cst,args) -> ( add_dep (md cst) ; List.iter mk_pattern args )
  | Lambda (_,_,te) -> mk_pattern te
  | Brackets t -> mk_term t

let mk_declaration _ _ _ t = mk_term t

let mk_definition _ _ = function
  | None -> mk_term
  | Some t -> mk_term t; mk_term

let mk_binding ( _,_, t) = mk_term t

let mk_prule (rule:untyped_rule) =
  mk_pattern rule.pat; mk_term rule.rhs

let mk_rules = List.iter mk_prule

let dfs graph visited start_node =
  let rec explore path visited node =
    if List.mem node path    then failwith "Circular dependencies"
    else
      if List.mem node visited then visited
      else
        let new_path = node :: path in
        let edges    = List.assoc node graph in
        let visited  = List.fold_left (explore new_path) visited edges in
        node :: visited
  in explore [] visited start_node

let topological_sort graph =
  List.fold_left (fun visited (node,_) -> dfs graph visited node) [] graph

let finalize () =
  let name, deps = List.hd !deps in
  md_to_file := (name, !filename)::!md_to_file;
  if not !sorted then
    print_out "%s.dko : %s %s" name !filename
              (String.concat " " (List.map (fun s -> s ^ ".dko") deps))
  else
    ()

let sort () = List.map (fun md -> List.assoc md !md_to_file) (List.rev (topological_sort !deps))

let mk_entry = function
  | Decl(lc,id,st,te) -> mk_declaration lc id st te
  | Def(lc,id,_,pty,te) -> mk_definition lc id pty te
  | Rules(rs) -> mk_rules rs
  | Eval(_, _, t) | Infer (_, _, t) -> mk_term t
  | Check(_,_,_, Convert(t1,t2)) | Check (_,_,_, HasType(t1,t2)) -> ( mk_term t1 ; mk_term t2 )
  | DTree _ | Print _                -> ()

let default_mident = ref None

let set_default_mident md = default_mident := Some md

let run_on_file file =
  if !(verbose) then Printf.eprintf "Running Dkdep on file \"%s\".\n" file;
  flush stderr;
  let input = open_in file in
  filename := file;
  let md =  Basic.mk_mident (match !default_mident with None -> file | Some str -> str) in
  init md;
  Parser.handle_channel md mk_entry input;
  finalize ();
  close_in input

let args =
  [ ("-o", Arg.String (fun fi -> out := open_out fi), "Output file"  );
    ("-v", Arg.Set verbose, "Verbose mode" );
    ("-s", Arg.Set sorted, "Sort file with respect to their dependence");
    ("-I", Arg.String Basic.add_path, "Add a directory to load path, dependencies to files found in load path are not printed");
    ("-module" , Arg.String set_default_mident     , "Give a default name to the current module");
  ]

let print_out fmt = Printf.kfprintf (fun _ -> output_string stdout "\n" ) stdout fmt

let _ =
  try
    Arg.parse args run_on_file "Usage: dkdep [options] files";
    if !sorted then
      let l = sort() in
      print_out "%s" (String.concat " " l)
  with
    | Sys_error err             -> Printf.eprintf "ERROR %s.\n" err; exit 1
    | Exit                      -> exit 3
