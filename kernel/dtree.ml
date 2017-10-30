open Basic
open Term
open Rule
open Format

type dtree_error =
  | HeadSymbolMismatch of loc * ident * ident
  | ArityMismatch of loc * ident
  | ArityInnerMismatch of loc * ident * ident

exception DtreeExn of dtree_error

(* A subtype of rule_infos with only the informations that the dtree need *)
type dtree_rule =
  { loc:loc ;
    pid:ident;
    pats:wf_pattern array ;
    right:term ;
    constraints:constr list ;
    esize:int ; }

let to_dtree_rule (r:rule_infos) : dtree_rule =
  { loc = r.l ;
    pid = r.id;
    pats = r.l_args ;
    right = r.rhs ;
    constraints = r.constraints ;
    esize = r.esize ; }

(*
 * there is one matrix per head symbol that represents all the rules associated to that symbol.
 * col_depth:   [ (n_0)          (n_1)          ...       (n_k)   ]
 * first:       [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 * others:      [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 *                  ...           ...           ...       ...
 *              [ pats.(0)      pats.(1)        ...     pats.(k)  ]
 *
 *              n_i records the depth of the column (number of binders under which it stands)
 *)
type matrix =
    { col_depth: int array;
      first:dtree_rule ;
      others:dtree_rule list ; }

(* mk_matrix lst builds a matrix out of the non-empty list of rules [lst]
*  It is checked that all rules have the same head symbol and arity.
* *)
let mk_matrix : rule_infos list -> matrix = function
  | [] -> assert false
  | r1::rs ->
    let n = Array.length r1.l_args in
    let o = List.map (
        fun r2 ->
          if not (ident_eq r1.id r2.id) then
            raise (DtreeExn (HeadSymbolMismatch (r2.l,r2.id,r1.id)))
          else
          if n != Array.length r2.l_args then
            raise (DtreeExn (ArityMismatch (r2.l,r1.id)))
          else
            to_dtree_rule r2
      ) rs in
    { first=(to_dtree_rule r1); others=o; col_depth=Array.make n 0 ;}

(* Remove a line of the matrix [mx] and return None if the new matrix is Empty. *)
let pop mx =
  match mx.others with
    | [] -> None
    | f::o -> Some { mx with first=f; others=o; }

let filter (f:dtree_rule -> bool) (mx:matrix) : matrix option =
  match List.filter f (mx.first::mx.others) with
    | [] -> None
    | f::o -> Some { mx with first=f; others=o; }

(* Keeps only the rules with a lambda on column [c] *)
let filter_on_lambda c r =
  match r.pats.(c) with
    | LLambda _ | LJoker | LVar _ -> true
    | _ -> false

(* Keeps only the rules with a bound variable of index [n] on column [c] *)
let filter_on_bound_variable c n r =
  match r.pats.(c) with
    | LBoundVar (_,m,_) when n==m -> true
    | LVar _ | LJoker -> true
    | _ -> false

(* Keeps only the rules with a pattern head by [m].[v] on column [c] *)
let filter_on_pattern c m v r =
  match r.pats.(c) with
    | LPattern (m',v',_) when ident_eq v v' && ident_eq m m' -> true
    | LVar _ | LJoker -> true
    | _ -> false

(* Keeps only the rules with a joker or a variable on column [c] *)
let filter_default (mx:matrix) (c:int) : matrix option =
  filter (
    fun r -> match r.pats.(c) with
      | LVar _ | LJoker -> true
      | LLambda _ | LPattern _ | LBoundVar _ -> false
  ) mx

type case =
  | CConst of int*ident*ident
  | CDB    of int*int
  | CLam

type arg_pos = { position:int; depth:int }
type abstract_problem = arg_pos * int LList.t


type matching_problem =
  | Syntactic of arg_pos LList.t
  | MillerPattern of abstract_problem LList.t

let pp_matching_problem fmt matching_problem =
  match matching_problem with
  | Syntactic _ -> fprintf fmt "Sy"
  | MillerPattern _ -> fprintf fmt "Mi"


type dtree =
  | Switch  of int * (case*dtree) list * dtree option
  | Test    of matching_problem * constr list * term * dtree option


let rec pp_dtree t fmt dtree =
  let tab = String.make (t*4) ' ' in
  match dtree with
  | Test (mp,[],te,None)   -> fprintf fmt "(%a) %a" pp_matching_problem mp pp_term te
  | Test (mp,[],te,def)      ->
    fprintf fmt "\n%sif true then (%a) %a\n%selse (%a) %a" tab pp_matching_problem mp pp_term te tab pp_matching_problem mp (pp_def (t+1)) def
  | Test (mp,lst,te,def)  ->
    let aux out = function
      | Linearity (i,j) -> fprintf out "%d =l %d" i j
      | Bracket (i,j) -> fprintf out "%a =b %a" pp_term (mk_DB dloc dmark i) pp_term j
    in
    fprintf fmt "\n%sif %a then (%a) %a\n%selse (%a) %a" tab (pp_list " and " aux) lst
      pp_matching_problem mp pp_term te tab pp_matching_problem mp (pp_def (t+1)) def
  | Switch (i,cases,def)->
    let pp_case out = function
      | CConst (_,m,v), g ->
        fprintf out "\n%sif $%i=%a.%a then %a" tab i pp_ident m pp_ident v (pp_dtree (t+1)) g
      | CLam, g -> fprintf out "\n%sif $%i=Lambda then %a" tab i (pp_dtree (t+1)) g
      | CDB (_,n), g -> fprintf out "\n%sif $%i=DB[%i] then %a" tab i n (pp_dtree (t+1)) g
    in
    fprintf fmt "%a\n%sdefault: %a" (pp_list "" pp_case)
      cases tab (pp_def (t+1)) def

and pp_def t fmt def =
  match def with
  | None        -> fprintf fmt "FAIL"
  | Some g      -> pp_dtree t fmt g

let pp_dtree fmt dtree = pp_dtree 0 fmt dtree

type rw = ident * ident * int * dtree

let pp_rw fmt (m,v,i,g) =
  fprintf fmt "GDT for '%a.%a' with %i argument(s): %a"
    pp_ident m pp_ident v i pp_dtree g


(* Specialize the rule [r] on column [c]
 * i.e. remove colum [c] and append [nargs] new column at the end.
 * These new columns contain
 * - the arguments if column [c] is a pattern
 * - or the body if column [c] is a lambda
 * - or Jokers otherwise
* *)
let specialize_rule (c:int) (nargs:int) (r:dtree_rule) : dtree_rule =
  let size = Array.length r.pats in
  let aux i =
    if i < size then
      if i==c then
        match r.pats.(c) with
          | LVar _ as v -> v
          | _ -> LJoker
      else r.pats.(i)
    else (* size <= i < size+nargs *)
      match r.pats.(c) with
        | LJoker | LVar _ -> LJoker
        | LPattern (_,id,pats2) | LBoundVar (id,_,pats2) ->
          if ( Array.length pats2 != nargs ) then
            raise (DtreeExn(ArityInnerMismatch(r.loc, r.pid, id)));
                pats2.( i - size)
        | LLambda (_,p) -> ( assert ( nargs == 1); p )
  in
    { r with pats = Array.init (size+nargs) aux }

(* Specialize the col_infos field of a matrix.
 * Invalid for specialization by lambda. *)
let spec_col_depth (c:int) (nargs:int) (col_depth: int array) : int array =
  let size = Array.length col_depth in
  let aux i =
    if i < size then col_depth.(i)
    else (* < size+nargs *) col_depth.(c)
  in
    Array.init (size+nargs) aux

(* Specialize the col_infos field of a matrix: the lambda case. *)
let spec_col_depth_l (c:int) (col_depth: int array) : int array =
  let size = Array.length col_depth in
  let aux i =
    if i < size then col_depth.(i)
    else (*i == size *) col_depth.(c) + 1
  in
    Array.init (size+1) aux

(* Specialize the matrix [mx] on column [c] *)
let specialize mx c case : matrix =
  let (mx_opt,nargs) = match case with
    | CLam -> ( filter (filter_on_lambda c) mx , 1 )
    | CDB (nargs,n) -> ( filter (filter_on_bound_variable c n) mx , nargs )
    | CConst (nargs,m,v) -> ( filter (filter_on_pattern c m v) mx , nargs )
  in
  let new_cn = match case with
    | CLam -> spec_col_depth_l c mx.col_depth
    | _ ->    spec_col_depth c nargs mx.col_depth
  in
    match mx_opt with
      | None -> assert false
      | Some mx2 ->
          { first = specialize_rule c nargs mx2.first;
            others = List.map (specialize_rule c nargs) mx2.others;
            col_depth = new_cn;
          }

(* ***************************** *)

let eq a b =
  match a, b with
    | CLam, CLam -> true
    | CDB (_,n), CDB (_,n') when n==n' -> true
    | CConst (_,m,v), CConst (_,m',v') when (ident_eq v v' && ident_eq m m') -> true
    | _, _ -> false

let partition (mx:matrix) (c:int) : case list =
  let aux lst li =
    let add h = if List.exists (eq h) lst then lst else h::lst in
      match li.pats.(c) with
        | LPattern (m,v,pats)  -> add (CConst (Array.length pats,m,v))
        | LBoundVar (_,n,pats) -> add (CDB (Array.length pats,n))
        | LLambda _ -> add CLam
        | LVar _ | LJoker -> lst
  in
    List.fold_left aux [] (mx.first::mx.others)

(* ***************************** *)

let array_to_llist arr =
  LList.make_unsafe (Array.length arr) (Array.to_list arr)

let get_first_term mx = mx.first.right
let get_first_constraints mx = mx.first.constraints

(* Extracts the matching_problem from the first line. *)
let get_first_matching_problem mx =
  let esize = mx.first.esize in
  let dummy = { position=(-1); depth=0; } in
  let dummy2 = dummy, LList.nil in
  let arr1 = Array.make esize dummy in
  let arr2 = Array.make esize dummy2 in
  let mp = ref false in
    Array.iteri
      (fun i p -> match p with
         | LJoker -> ()
         | LVar (_,n,lst) ->
             begin
               let k = mx.col_depth.(i) in
               assert( 0 <= n-k );
               assert(n-k < esize );
               let pos = { position=i; depth = mx.col_depth.(i) } in
               arr1.(n-k) <- pos;
               if lst=[] then
                   arr2.(n-k) <- pos, LList.nil
               else (
                 mp := true ;
                 arr2.(n-k) <- pos,LList.of_list lst
               )
             end
         | _ -> assert false
      ) mx.first.pats ;
    ( Array.iter ( fun r -> assert (r.position >= 0 ) ) arr1 );
    if !mp then MillerPattern (array_to_llist arr2)
    else Syntactic (array_to_llist arr1)

(******************************************************************************)

(* Give the index of the first non variable column *)
let choose_column mx =
  let rec aux i =
    if i < Array.length mx.first.pats then
      ( match mx.first.pats.(i) with
        | LPattern _ | LLambda _ | LBoundVar _ -> Some i
        | LVar _ | LJoker -> aux (i+1) )
    else None
  in aux 0

(* Construct a decision tree out of a matrix *)
let rec to_dtree (mx:matrix) : dtree =
  match choose_column mx with
    (* There are only variables on the first line of the matrix *)
    | None   -> Test ( get_first_matching_problem mx,
                       get_first_constraints mx,
                       get_first_term mx,
                       map_opt to_dtree (pop mx) )
    (* Pattern on the first line at column c *)
    | Some c ->
        let cases = partition mx c in
        let aux ca = ( ca , to_dtree (specialize mx c ca) ) in
          Switch (c, List.map aux cases, map_opt to_dtree (filter_default mx c) )

(******************************************************************************)


let of_rules (rs:rule_infos list) : (int*dtree,dtree_error) error =
  try
    let mx = mk_matrix rs in OK ( Array.length mx.first.pats , to_dtree mx )
  with DtreeExn e -> Err e
