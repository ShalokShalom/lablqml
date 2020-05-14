open Stdio
open Base
open Printf

module Time = struct
  let now () = Unix.(localtime @@ time() )
  let months = [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec" |]
  let str_of_month n =
    if n>=0 && n<=12 then months.(n)
    else failwith "Wrong argument of str_of_month"
  let to_string {Unix.tm_sec; Unix.tm_mon; Unix.tm_min; Unix.tm_hour; Unix.tm_mday; Unix.tm_year; _ } =
    sprintf "%02d %s, %d %02d:%02d:%02d"
            tm_mday (str_of_month tm_mon) (1900+tm_year) tm_hour tm_min tm_sec
end


let printfn fmt = ksprintf (Caml.Format.printf "%s\n") fmt
let fprintfn ch fmt = ksprintf (Stdio.Out_channel.fprintf ch "%s\n%!") fmt

let print_time ch =
  fprintfn ch "/*";
  fprintfn ch " * Generated at %s" Time.(now () |> to_string);
  fprintfn ch " */"


let ref_append ~set x = set := x :: !set

module Ref = struct
  include Ref
  let append = ref_append
  let replace x f = (x := f !x)
end


module Options = struct
  type t = [ `Instantiable | `ItemModel ] list
  let myfind x ~set = List.mem set x ~equal:Stdlib.(=)
  let is_itemmodel set = myfind `ItemModel ~set
  let has_itemmodel set =
    List.find_map set ~f:(function `Itemmodel x -> Some x | _ -> None)

end

module FilesKey = struct
  type ext = CSRC | CHDR
  type t = string * ext
  let cmp_string : string -> string -> int = String.compare
  let compare a b = match a,b with
    | (_,CSRC),(_,CHDR) -> -1
    | (_,CHDR),(_,CSRC) ->  1
    | (x,_),(y,_) -> cmp_string x y
end
module FilesMap = Stdlib.Map.Make(FilesKey)

let files = ref FilesMap.empty

let open_files ?(destdir=".") ?(ext="cpp") ~options ~classname =
  (*print_endline "Opening files....";*)
  let src = Stdio.Out_channel.create (sprintf "%s/%s_c.%s" destdir classname ext) in
  let hdr = Stdio.Out_channel.create (sprintf "%s/%s.h" destdir classname) in
  print_time hdr;
  let println fmt = fprintfn hdr fmt in
  println "#ifndef %s_H" (Stdlib.String.uppercase_ascii classname);
  println "#define %s_H" (Stdlib.String.uppercase_ascii classname);
  println "";
  println "#include <QtCore/QDebug>";
  println "#include <QtCore/QObject>";
  println "#include <QtCore/QAbstractItemModel>";
  println "";
  println "#ifdef __cplusplus";
  println "extern \"C\" {";
  println "#endif";
  println "#include <caml/alloc.h>";
  println "#include <caml/mlvalues.h>";
  println "#include <caml/callback.h>";
  println "#include <caml/memory.h>";
  println "#include <caml/threads.h>";
  println "#ifdef __cplusplus";
  println "}";
  println "#endif";
  println "";
  println "class %s : public %s {" classname
           (if Options.is_itemmodel options then "QAbstractItemModel" else "QObject");
  println "  Q_OBJECT";
  println "  value _camlobjHolder; // store reference to OCaml value there";
  println "public:";
  println "  %s() : _camlobjHolder(0) { };" classname;
  println "  void storeCAMLobj(value x) {";
  println "    if (_camlobjHolder != 0) {";
  println "       //maybe unregister global root?";
  println "    }";
  println "    _camlobjHolder = x;";
  println "    register_global_root(&_camlobjHolder);";
  println "  }\n";
  let () =
    if Options.is_itemmodel options then (
      println "private:";
      println "  QHash<int, QByteArray> _roles;";
      println "public:";
      println "  QModelIndex makeIndex(int row,int column) const {";
      println "    if (row==-1 || column==-1)";
      println "      return QModelIndex();";
      println "    else";
      println "      return createIndex(row,column,(void*)NULL);";
      println "  }";
      println "  QList<QString> roles() {";
      println "    QList<QString> ans;";
      println "    foreach(QByteArray b, _roles.values() )";
      println "      ans << QString(b);";
      println "    return ans;";
      println "  }";
      println "  void addRole(int r, QByteArray name) { _roles.insert(r,name); }";
      println "  virtual QHash<int, QByteArray> roleNames() const { return _roles; }";
      println "  void emit_dataChanged(int a, int b, int c, int d) {";
      println "    const QModelIndex topLeft     = createIndex(a,b);";
      println "    const QModelIndex bottomRight = createIndex(c,d);";
      println "    emit dataChanged(topLeft, bottomRight);";
      println "  }";
      println "";

    )
  in

  files := FilesMap.(add (classname, FilesKey.CHDR) hdr !files);
  print_time src;
  fprintfn src "#include \"%s.h\"" classname;
  fprintfn src "";
  files := FilesMap.(add (classname, FilesKey.CSRC) src !files);
  ()

let enter_blocking_section ch =
  fprintfn ch "  caml_release_runtime_system();";
  ()

let leave_blocking_section ch =
  fprintfn ch "  caml_acquire_runtime_system();";
  ()

let close_files ~options:_ =
  (*print_endline "Closing files";*)
  let f (classname,ext) hndl =
    let println fmt = fprintfn hndl fmt in
    match ext with
    | FilesKey.CHDR ->
       println "};";
       println "#endif /* %s_H */\n" (Stdlib.String.uppercase_ascii classname);
       println "extern \"C\" value caml_create_%s(value _dummyUnitVal);" classname;
       println "extern \"C\" value caml_store_value_in_%s(value _cppobj,value _camlobj);" classname;
       (*
       if List.mem `Instantiable options
       then
         println "extern \"C\" value caml_register_%s(value _ns,value _major,value _minor,value _classname,value _constructor);" classname;
       *)
       Stdio.Out_channel.flush hndl;
       Stdio.Out_channel.close hndl
    | FilesKey.CSRC ->
       (* we need to generate stubs for creating C++ object there *)
       println "extern \"C\" value caml_create_%s(value _dummyUnitVal) {" classname;
       println "  CAMLparam1(_dummyUnitVal);";
       println "  CAMLlocal1(_ans);";
       enter_blocking_section hndl;
       println "  _ans = caml_alloc_small(1, Abstract_tag);";
       println "  (*((%s **) &Field(_ans, 0))) = new %s();" classname classname;
       leave_blocking_section hndl;
       println "  CAMLreturn(_ans);";
       println "}\n";

       println "extern \"C\" value caml_store_value_in_%s(value _cppobj,value _camlobj) {" classname;
       println "  CAMLparam2(_cppobj,_camlobj);";
       enter_blocking_section hndl;
       println "  %s *o = (%s*) (Field(_cppobj,0));" classname classname;
       println "  o->storeCAMLobj(_camlobj);";
       leave_blocking_section hndl;
       println "  CAMLreturn(Val_unit);";
       println "}";
(*
        println "extern \"C\" value caml_register_%s(value _ns,value _major,value _minor,value _classname,value _constructor) {" classname;
        println "  CAMLparam5(_ns, _major, _minor, _classname, value _constructor);";
        enter_blocking_section hndl;
        println "  int major = Int_val(_major);";
        println "  int minor = Int_val(_minor);";
        println "  QString ns = QString(String_val(_minor));";
        println "  QString cname = QString(String_val(_classname));";
        println "  qmlRegisterType<%s>(ns, major, minor, cname);" classname;
        println "  o->storeCAMLobj(_camlobj);";
        leave_blocking_section hndl;
        println "  CAMLreturn(Val_unit);";
        println "}";*)

        Stdio.Out_channel.flush hndl;
        Stdio.Out_channel.close hndl
  in
  FilesMap.iter f !files;
  files := FilesMap.empty

module Names = struct
  let signal_of_prop s = s^"Changed"
  let getter_of_prop s = "get"^s
  let setter_of_prop s = "set"^s
end

exception VaribleStackEmpty

let get_vars_queue xs =
  let stack = ref xs in
  let get_var () = match !stack with
    | x::xs -> stack:= xs; x
    | [] -> raise VaribleStackEmpty
  in
  let release_var name = Ref.replace stack (fun xs -> name::xs) in
  (get_var,release_var)

let getter_of_cppvars  prefix =
  let last_index = ref 0 in
  let f () =
    Int.incr last_index;
    sprintf "%s%d" prefix !last_index
    in
    f

(* TODO: add addtitional info about methods *)
(* We need this arginfo because void foo(QString) is not the same as void foo(const QString&) *)
type arg_info = { ai_ref: bool; ai_const: bool }
type meth_info = { mi_virt: bool; mi_const: bool }
(*
type simple_types = [ `variant | `bytearray | `bool | `int | `string  ]
(* properties can have only simple types (except unit) *)
type prop_typ = [ simple_types | `list of prop_typ ]
type meth_typ_item =
  [ `unit | simple_types | `list of meth_typ_item
  | `modelindex | `cppobj
  ]
type meth_typ = (meth_typ_item * arg_info) list
*)
let mi_empty = { mi_virt=false; mi_const=false }
let ai_empty = { ai_ref=false; ai_const=false }
let wrap_typ_simple x = (x, ai_empty)
let unref   (x, y) = (x, { y with ai_ref=false })
let unconst (x, y) = (x, { y with ai_const=false })

module Arg : sig
  type default = [ `Default ]
  type model = [ `Model ]
  type cppobj = [ `Cppobj ]
  type non_cppobj = [ default | model ]
  type any = [ cppobj | non_cppobj ]

  type +'a t = private
    | Unit | QString | Int | Bool | QVariant | QByteArray
    | QList of 'a t
    | QModelIndex
    | Cppobj

  val int : default t
  val bool: default t
  val qstring : default t
  val unit : default t
  val variant : default t
  val bytearray : default t
  val qlist  : 'a t -> 'a t

  val obj : cppobj t
  val cppobj : cppobj t
  val modelindex : model t


(*  val foo : [ default | model ] t -> int*)
end = struct
  type default = [ `Default ]
  type model = [ `Model ]
  type cppobj = [ `Cppobj ]
  type non_cppobj = [ default | model ]
  type any = [ cppobj | non_cppobj ]

  type 'a t =
    | Unit | QString | Int | Bool | QVariant | QByteArray
    | QList of 'a t
    | QModelIndex
    | Cppobj

  let int = Int
  let bool = Bool
  let qstring = QString
  let unit = Unit
  let variant = QVariant
  let bytearray = QByteArray
  let qlist xs = QList xs

  let modelindex = QModelIndex
  let obj = Cppobj
  let cppobj = Cppobj

(*  let foo _ = 1*)

end

open Arg

(* how many additional variables needed to convert C++ value to OCaml one *)
let aux_variables_count : _ Arg.t -> int =
  let rec helper = function
    | QVariant -> 2
    | Cppobj -> failwith "not implemented"
    | QByteArray
    | Bool | Int | Unit | QString | QModelIndex -> 0
    | QList x -> helper x + 2
  in
  helper

(* how many additional variables needed to convert OCaml value to C++ one *)
let aux_variables_count_to_cpp : _ Arg.t -> int =
  let rec helper = function
    | QVariant
    | QByteArray
    | Bool | Int | Unit | QString | QModelIndex -> 0
    | Cppobj -> failwith "not implemented"
    | QList x -> helper x + 2
  in
  helper

let rec ocaml_ast_of_typ : _ Arg.t -> Longident.t = fun x ->
  let open Longident in
  match x with
  | Cppobj     -> Lident "cppobj"
  | QVariant   -> Ldot (Lident "QVariant",   "t")
  | QModelIndex-> Ldot (Lident "QModelIndex","t")
  | Bool       -> Lident "bool"
  | Unit       -> Lident "unit"
  | QByteArray
  | QString    -> Lident "string"
  | Int        -> Lident "int"
  | QList x    -> Lapply (Lident "list", ocaml_ast_of_typ x)

let cpptyp_of_typ: non_cppobj Arg.t * _ -> string =
  let rec helper (x,ai) =
    match x with
    | Bool -> "bool"
    | Int  -> "int"
    | QVariant -> "QVariant"
    | QString    -> "QString"
    | QByteArray -> "QByteArray"
    | Unit    -> "void"
    | Cppobj -> failwith "Bug. cppobj can't appear in C++"
    | QModelIndex -> sprintf "%sQModelIndex%s" (if ai.ai_const then "const " else "")
                             (if ai.ai_ref then "&" else "")
    | QList x -> sprintf "%sQList<%s>%s" (if ai.ai_const then "const " else "")
                         (helper (x,{ai_ref=false;ai_const=false}))
                         (if ai.ai_ref then "&" else "")
  in
  helper
  (*
  match x with
  | `cppobj  -> failwith "Bug. cppobj can't appear in C++"
  | `bool    -> helper (`bool,ai)
  | `bytearray-> helper (`bytearray,ai)
  | `int     -> helper (`int, ai)
  | `unit    -> helper (`unit, ai)
  | `variant -> helper (`variant, ai)
  | `list a  -> helper (`list a,ai)
  | `string  -> helper (`string,ai)
  | `modelindex -> helper (`modelindex,ai)
*)

let rec cpptyp_of_proptyp: (default Arg.t) * arg_info -> string = fun ((typ,ai) as x) ->
  let upcasted = (x :> non_cppobj Arg.t * arg_info) in
  let cppname =
    match typ with
    | Bool -> cpptyp_of_typ upcasted
    | Int  -> cpptyp_of_typ upcasted
    | QVariant -> cpptyp_of_typ upcasted
    | QByteArray -> cpptyp_of_typ upcasted
    | QString    -> cpptyp_of_typ upcasted

    | Unit -> failwith "should not happen"
    | QModelIndex -> failwith "should not happen"
    | Cppobj  -> failwith "should not happen"
    | QList x ->
        sprintf "QList<%s>"
        (cpptyp_of_proptyp (x,{ai_ref=false;ai_const=false}))

  in
  sprintf "%s%s%s"
    (if ai.ai_const then "const " else "")
    cppname
    (if ai.ai_ref then "&" else "")


let print_declarations ?(mode=`Local) ch xs =
  let m = match mode with `Local -> "CAMLlocal" | `Param -> "CAMLparam" in
  let rec helper = function
  | a::b::c::d::e::xs ->
     Stdio.Out_channel.fprintf ch "  %s5(%s);\n" m (String.concat ~sep:"," [a;b;c;d;e]);
     helper xs
  | [] -> ()
  | xs ->
     let n = List.length xs in
     assert (n<5);
     Stdio.Out_channel.fprintf ch "  %s%d(%s);\n" m n (String.concat ~sep:"," xs)
  in
  helper xs

let print_local_declarations ch xs = print_declarations ~mode:`Local ch xs
let print_param_declarations ch xs = print_declarations ~mode:`Param ch xs

let cpp_value_of_ocaml ?(options=[]) ~cppvar ~ocamlvar
                       ch (get_var,release_var,new_cpp_var) : non_cppobj Arg.t -> unit =
  let rec helper ~tab dest ~ocamlvar typ =
    let prefix = String.make (2*tab) ' ' in
    let println fmt = Stdio.Out_channel.fprintf ch "%s" prefix; fprintfn ch fmt in
    match typ with
    | Unit       -> ()
    | Cppobj     -> failwith "should not happen"
    | Int        -> println "%s = Int_val(%s);" dest ocamlvar
    | QString    -> println "%s = QString(String_val(%s));" dest ocamlvar
    | QByteArray -> println "%s = QByteArray(String_val(%s));" dest ocamlvar
    | Bool       -> println "%s = Bool_val(%s);" dest ocamlvar
    | QModelIndex ->
       begin
         match Options.has_itemmodel options with
         | Some obj ->
            let call =
              match obj with
              | Some o -> sprintf "%s->makeIndex" o
              | None  -> "createIndex"
            in
            println "%s = %s(Int_val(Field(%s,0)), Int_val(Field(%s,1)) );"
                    dest call ocamlvar ocamlvar
         | None -> failwith "QModelIndex is not available without QAbstractItemModel base"
       end
    | QVariant ->
       println "if (Is_block(%s)) {" ocamlvar;
       println "  if (caml_hash_variant(\"string\") == Field(%s,0))" ocamlvar;
       println "    %s = QVariant::fromValue(QString(String_val(Field(%s,1))));" dest ocamlvar;
       println "  else if(caml_hash_variant(\"int\") == Field(%s,0))" ocamlvar;
       println "    %s = QVariant::fromValue(Int_val(Field(%s,1)));" dest ocamlvar;
       println "  else if(caml_hash_variant(\"bool\") == Field(%s,0))" ocamlvar;
       println "    %s = QVariant::fromValue(Bool_val(Field(%s,1)));" dest ocamlvar;
       println "  else if(caml_hash_variant(\"float\") == Field(%s,0))" ocamlvar;
       println "    %s = QVariant::fromValue(Double_val(Field(%s,1)));" dest ocamlvar;
       println "  else if(caml_hash_variant(\"qobject\") == Field(%s,0))" ocamlvar;
       println "    %s = QVariant::fromValue((QObject*) (Field(Field(%s,1),0)));" dest ocamlvar;
       println "  else Q_ASSERT_X(false,\"%s\",\"%s\");"
                 "While converting OCaml value to QVariant"
                 "Unknown variant tag";
       println "} else { // empty QVariant";
       println "    %s = QVariant();" dest;
       println "}"
    | QList t->
       let cpp_typ_str =
         (*let u : [`cppobj|meth_typ_item] * _ =
           ((wrap_typ_simple typ) :> ([`cppobj|meth_typ_item]*arg_info)) in*)
         let u = wrap_typ_simple typ in
         cpptyp_of_typ u
       in
       let cpp_argtyp_str = cpptyp_of_typ @@
(*                              ((wrap_typ_simple t) :> ([`cppobj|meth_typ_item]*arg_info) )*)
                              (wrap_typ_simple t)
       in
       println "// generating %s" cpp_typ_str;
       let temp_var = get_var () in
       let head_var = get_var () in
       let temp_cpp_var = new_cpp_var () in
       println "%s = %s;\n" temp_var ocamlvar;
       println "while (%s != Val_emptylist) {\n" temp_var;
       println "  %s = Field(%s,0); /* head */"  head_var temp_var;
       println "  %s %s;" cpp_argtyp_str temp_cpp_var;
       helper  ~tab:(tab+1) temp_cpp_var ~ocamlvar:head_var t;
       println "  %s << %s;\n" dest temp_cpp_var;
       println "  %s = Field(%s,1);" temp_var temp_var;
       println "}";
       release_var head_var;
       release_var temp_var
  in
  helper ~tab:1 cppvar ~ocamlvar

let ocaml_value_of_cpp ch (get_var,release_var) ~ocamlvar ~cppvar : non_cppobj Arg.t -> unit =
  let rec helper ~tab ~var ~dest typ =
    let println fmt = Out_channel.fprintf ch "%s" (String.make (2*tab) ' '); fprintfn ch fmt in
    match typ with
    | Cppobj     -> failwith "should not happen"
    | Unit       -> failwith "Can't generate OCaml value from C++ void a.k.a. unit"
    | Int        -> println "%s = Val_int(%s);" dest var
    | Bool       -> println "%s = Val_bool(%s);" dest var
    | QString     -> println "%s = caml_copy_string(%s.toLocal8Bit().data());" dest var
    | QByteArray  -> println "%s = caml_copy_string(%s.toLocal8Bit().data());" dest var
    | QModelIndex ->
       println "%s = caml_alloc(2,0);" dest;
       println "Store_field(%s,0,Val_int(%s.row()));" dest var;
       println "Store_field(%s,1,Val_int(%s.column()));" dest var
    | QVariant ->
       println "if (!%s.isValid())" var;
       println "  %s=hash_variant(\"empty\");" dest;
       println "else {";
       println "  int ut = %s.userType();" var;
       println "  if(ut == QMetaType::QString) {";
       println "    %s = caml_alloc(2,0);" dest;
       println "    Store_field(%s,0,%s);" dest "hash_variant(\"string\")";
       println "    Store_field(%s,1,%s);" dest
                 (sprintf "caml_copy_string(%s.value<QString>().toLocal8Bit().data())" var);
       println "  } else if (ut == QMetaType::Int) { ";
       println "    %s = caml_alloc(2,0);" dest;
       println "    Store_field(%s, 0, %s);" dest "hash_variant(\"int\")";
       println "    Store_field(%s, 1, Val_int(%s.value<int>()));" dest var;
       println "  } else if (ut == QMetaType::Double) { ";
       println "    %s = caml_alloc(2,0);" dest;
       println "    Store_field(%s, 0, %s);" dest "hash_variant(\"float\")";
       println "    Store_field(%s, 1, caml_copy_double(%s.value<double>()) );" dest var;
       println "  } else if (ut == QMetaType::Bool) { ";
       println "    %s = caml_alloc(2,0);" dest;
       println "    Store_field(%s, 0, %s);" dest "hash_variant(\"bool\")";
       println "    Store_field(%s, 1, Val_bool(%s.value<bool>()));" dest var;
       println "  } else if((ut==QMetaType::User) ||";
       println "            (ut==QMetaType::QObjectStar)) {"; (*custom QObject*)
       println "    QObject *vvv = %s.value<QObject*>();" var;
       let objvar = get_var() in
       println "    %s = caml_alloc_small(1,Abstract_tag);" objvar;
       println "    (*((QObject **) &Field(%s, 0))) = vvv;" objvar;
       println "    %s = caml_alloc(2,0);" dest;
       println "    Store_field(%s, 0, hash_variant(\"qobject\"));" dest;
       println "    Store_field(%s, 1, %s);" dest objvar;
       println "  } else {";
       println "    QString msg(\"Type is not supported:\");";
       println "    msg += QString(\"userType() == %%1\").arg(ut);";
       println "    Q_ASSERT_X(false,\"qVariant_of_cpp\", msg.toLocal8Bit().data() );";
       println "  }";
       println "}"

    | QList t ->
       let cons_helper = get_var () in
       let cons_arg_var = get_var () in
       println "%s = Val_emptylist;\n" dest;
       println "if ((%s).length() != 0) {" var;
       println "  auto it = (%s).end() - 1;" var;
       println "  for (;;) {";
       println "    %s = caml_alloc(2,0);" cons_helper;
       helper ~tab:(tab+1) ~var:"(*it)" ~dest:cons_arg_var t;
       println "    Store_field(%s, 0, %s);" cons_helper cons_arg_var;
       println "    Store_field(%s, 1, %s);" cons_helper dest;
       println "    %s = %s;" dest cons_helper;
       println "    if ((%s).begin() == it) break;" var;
       println "    it--;";
       println "  }";
       println "}";
       release_var cons_arg_var;
       release_var cons_helper;
       println "";
    ()
  in
  helper ~tab:1 ~var:cppvar ~dest:ocamlvar

(* stub implementation to call it from OCaml *)
let gen_stub_cpp ?(options=[]) ~classname ~stubname ~methname ch
                 (types: (non_cppobj Arg.t * arg_info) list) =
  let println fmt = fprintfn ch fmt in
  let (args,res) = List.(drop_last_exn types, last_exn types) in
  let res = unref res in
  println "// stub: %s name(%s)" (cpptyp_of_typ res) (List.map ~f:cpptyp_of_typ args |> String.concat ~sep:",");
  let argnames = List.mapi ~f:(fun i _ -> sprintf "_x%d" i) args in
  let cppvars  = List.mapi ~f:(fun i _ -> sprintf "z%d" i) args in
  println "extern \"C\" value %s(%s) {"
          stubname
          (match args with
           (*| [(`unit,_)] -> "value _cppobj"*)
           | _ -> List.map ~f:(sprintf "value %s") ("_cppobj"::argnames) |> String.concat ~sep:",");
  print_param_declarations ch ("_cppobj"::argnames);
  let aux_count =
    List.fold_left ~f:(fun acc x -> max (aux_variables_count_to_cpp @@ fst x) acc) ~init:0 args
  in
  let aux_count = max aux_count (aux_variables_count @@ fst res) in
  println "  // aux vars count = %d" aux_count;
  let local_names = List.init ~f:(sprintf "_x%d") aux_count in
  print_local_declarations ch local_names;

  enter_blocking_section ch;
  println "  %s *o = (%s*) (Field(_cppobj,0));" classname classname;

  let get_var,release_var = get_vars_queue local_names in
  let cpp_var_counter = ref 0 in
  let new_cpp_var () = Int.incr cpp_var_counter; sprintf "zz%d" !cpp_var_counter in

  let options = if Options.is_itemmodel options then [`ItemModel (Some "o")] else [] in
  let f = fun i arg ->
    let cppvar = sprintf "z%d" i in
    let ocamlvar = sprintf "_x%d" i in
    println "  %s %s;" (cpptyp_of_typ arg) cppvar;
    cpp_value_of_ocaml ch ~options ~cppvar ~ocamlvar (get_var,release_var,new_cpp_var) (fst arg)
  in
  List.iteri ~f args;
  let () = match res with
    | (Unit,_) ->
       println "  o->%s(%s);" methname (String.concat ~sep:"," cppvars);
       leave_blocking_section ch;
       println "  CAMLreturn(Val_unit);";
    | (_t, _ai)   ->
       let cppvar = "res" in
       println "  %s %s = o->%s(%s);" (cpptyp_of_typ res) cppvar methname (String.concat ~sep:"," cppvars);
       let ocamlvar = "_ans" in
       Out_channel.fprintf ch "  ";
       ocaml_value_of_cpp ch (get_var,release_var) ~ocamlvar ~cppvar (fst res);
       leave_blocking_section ch;
       println "  CAMLreturn(%s);" ocamlvar
  in
  println "}";
  ()

(* method implementation from class header. Used for invacation OCaml from C++ *)
let gen_meth_cpp ~minfo ?(options=[]) ~classname ~methname ch types =
  let _ = options in
  let println fmt = fprintfn ch fmt in
  let print   fmt = Out_channel.fprintf  ch fmt in
  fprintfn ch "// %s::%s: %s" classname methname
    (List.map ~f:cpptyp_of_typ types |> String.concat ~sep:",");
  let (args,res) = List.(drop_last_exn types, last_exn types) in
  let res = unconst @@ unref res in
  let () =
    match fst res with
    | Unit -> print "void "
    | _     -> print "%s " (cpptyp_of_typ res)
  in
  println "%s::%s(%s) %s {" classname methname
          (match args with
           | [(Unit,_)] -> ""
           | _ ->
              String.concat ~sep:"," @@
              List.mapi ~f:(fun i t -> sprintf "%s x%d" (cpptyp_of_typ t) i) args)
          (if minfo.mi_const then " const" else "");
  println "  CAMLparam0();";
  let locals_count = 2 +
    List.fold_left ~f:(fun acc (x,_) -> max acc (aux_variables_count x)) ~init:0 types
  in
  let locals = List.init ~f:(sprintf "_x%d") (locals_count-1) in
  print_local_declarations ch ("_ans" :: "_meth" :: locals);
  (* array for invoking OCaml method *)
  println "  CAMLlocalN(_args,%d);" (List.length args + 1);
  (*println "  // aux vars count = %d" locals_count; *)
  let make_cb_var = sprintf "_cca%d" in (* generate name *)
  let cb_locals = List.mapi ~f:(fun i _ -> make_cb_var i) args in
  print_local_declarations ch cb_locals;
  leave_blocking_section ch;

  println "  value _camlobj = this->_camlobjHolder;";
  println "  Q_ASSERT(Is_block(_camlobj));";
  println "  Q_ASSERT(Tag_val(_camlobj) == Object_tag);";
  println "  _meth = caml_get_public_method(_camlobj, caml_hash_variant(\"%s\"));" methname;

  let get_var,release_var = get_vars_queue locals in
  let call_closure_str = match List.length args with
    | 0
    | 1 when (match args with [Unit,_] -> true | _ -> false) ->
       sprintf "caml_callback2(_meth, _camlobj, Val_unit);"
    | n ->
       println "  _args[0] = _camlobj;";
       let f i (typ,_) =
         let cppvar = sprintf "x%d" i in
         let ocamlvar = make_cb_var i in
         Out_channel.fprintf ch "  ";
         (*fprintfn stdout "call ocaml_value_of_cpp %s" (cpptyp_of_typ arg);*)
         ocaml_value_of_cpp ch (get_var,release_var) ~ocamlvar ~cppvar typ;
         println "  _args[%d] = %s;" (i+1) ocamlvar
       in
       List.iteri ~f  args;
       sprintf "caml_callbackN(_meth, %d, _args);" (n+1)
  in
  let () =
    match fst res with
    | Unit  ->
      println "  %s" call_closure_str;
      enter_blocking_section ch;
      println "  CAMLreturn0;"
    | _ ->
      let options = [`ItemModel (Some "this")] in
      let ocamlvar = "_ans" in
      let cpp_res_typ = cpptyp_of_typ res in
      println "  %s = %s;" ocamlvar call_closure_str;
      enter_blocking_section ch;
      let cppvar = "cppans" in
      println "  %s %s;" cpp_res_typ cppvar;
      let new_cpp_var = getter_of_cppvars "xx" in
      cpp_value_of_ocaml ~options ~cppvar ~ocamlvar ch (get_var,release_var, new_cpp_var) (fst res);
      println "  CAMLreturnT(%s,%s);" cpp_res_typ cppvar;
  in
  println "}";
  ()

let gen_prop ~classname ~propname (typ: default Arg.t) =
  (*printf "Generation prop '%s' of class '%s'.\n" propname classname;*)
  let println fmt =
    let hndl = FilesMap.find (classname,FilesKey.CHDR) !files in
    fprintfn hndl fmt
  in
  let sgnl_name = Names.signal_of_prop propname in
  let getter_name = Names.getter_of_prop propname in
  (*let setter_name = Names.setter_of_prop propname in*)
  let cpptyp_name = cpptyp_of_proptyp @@ wrap_typ_simple typ in

  println "public:";
  println "  Q_PROPERTY(%s %s READ %s NOTIFY %s)" cpptyp_name propname getter_name sgnl_name;
  println "  Q_INVOKABLE %s %s();" cpptyp_name getter_name;
  println "signals:";
  println "  void %s(%s %s);" sgnl_name cpptyp_name propname;
  (* C++ part now *)
  let hndl = FilesMap.find (classname,FilesKey.CSRC) !files in
  (*println "// Q_PROPERTY( %s )" propname;*)
  gen_meth_cpp ~classname ~methname:getter_name hndl ~minfo:{mi_const=false;mi_virt=false}
               (* TODO: maybe we can use cosnt and & for setter argument *)
               [ ((unit  :> non_cppobj Arg.t), ai_empty)
               ; ((typ   :> non_cppobj Arg.t), ai_empty)
               ];
  let stubname: string  = sprintf "caml_%s_%s_cppmeth_wrapper" classname sgnl_name in
  gen_stub_cpp ~classname ~methname:sgnl_name ~stubname
               hndl
               [ ((typ   :> non_cppobj Arg.t), ai_empty)
               ; ((unit  :> non_cppobj Arg.t), ai_empty)
               ];
  ()

let gen_signal ~classname ~signalname types' =
  (* args are sent without last unit *)
  let hndl = FilesMap.find (classname, FilesKey.CHDR) !files in
  let types = List.map types' ~f:snd in
  let argnames = List.map types' ~f:fst in

  (*let () = List.iter ~f:(fun x -> assert(x<>"")) argnames in *)
  (*let () = List.iter ~f:(fun x -> print_endline x) argnames in*)

  let println fmt = fprintfn hndl fmt in
  println "signals:";
  let types = List.map types ~f:wrap_typ_simple in
  let f t name = sprintf "%s %s" (cpptyp_of_typ t) name in
  println "  void %s(%s);" signalname (List.map2_exn ~f types argnames |> String.concat);

  let stubname: string  = sprintf "caml_%s_%s_emitter_wrapper" classname signalname in
  let hndl = FilesMap.find (classname, FilesKey.CSRC) !files in
  gen_stub_cpp ~options:[] ~classname ~methname:signalname ~stubname
               hndl
               (types @ [((unit  :> non_cppobj Arg.t), ai_empty)] );
  ()


let gen_meth ?(minfo=mi_empty) ?(options=[]) ~classname ~methname typ =
  let (_: non_cppobj t list) = typ in
  (*printf "Generation meth '%s' of class '%s'.\n" methname classname;*)
  let typ' = List.map typ ~f:(function
                            | QModelIndex -> ((modelindex :> non_cppobj Arg.t), {ai_const=true;ai_ref=true})
                            | x -> wrap_typ_simple x )
  in
  let (args,res) = List.(drop_last_exn typ', last_exn typ') in
  let hndl = FilesMap.find (classname, FilesKey.CHDR) !files in
  fprintfn hndl "public:";
  fprintfn hndl "  Q_INVOKABLE %s %s(%s)%s%s;"
           (cpptyp_of_typ @@ unconst @@ unref res)
           methname
           (List.mapi ~f:(fun _ -> cpptyp_of_typ) args |> String.concat ~sep:",")
           (if minfo.mi_const then " const" else "")
           (if minfo.mi_virt then " override" else "");

  let hndl = FilesMap.find (classname,FilesKey.CSRC) !files in
  let options = if Options.is_itemmodel options then [`ItemModel] else [] in
  gen_meth_cpp ~minfo ~options ~classname ~methname hndl typ';
  ()

let itemmodel_externals ~classname :
  (string * string * [ cppobj | model | default ] Arg.t list) list =
  [ ("dataChanged", sprintf "caml_%s_dataChanged_cppmeth_wrapper" classname,
     [ (cppobj     :> any Arg.t)
     ; (modelindex :> any Arg.t)
     ; (modelindex :> any Arg.t)
     ; (unit       :> any Arg.t)
     ])
  ; ("beginInsertRows", sprintf "caml_%s_beginInsertRows_cppmeth_wrapper" classname,
     [ (cppobj :> any Arg.t)
     ; (modelindex :> any Arg.t)
     ; (int        :> any Arg.t)
     ; (int         :> any Arg.t)
     ; (unit       :> any Arg.t)
     ])
  ; ("endInsertRows", sprintf "caml_%s_endInsertRows_cppmeth_wrapper" classname,
     [ (cppobj :> any Arg.t)
     ; (unit       :> any Arg.t)
     ])
  ; ("beginRemoveRows", sprintf "caml_%s_beginRemoveRows_cppmeth_wrapper" classname,
     [ (cppobj :> any Arg.t)
     ; (modelindex :> any Arg.t)
     ; (int         :> any Arg.t)
     ; (int         :> any Arg.t)
     ; (unit       :> any Arg.t)
     ])
  ; ("endRemoveRows", sprintf "caml_%s_endRemoveRows_cppmeth_wrapper" classname,
     [ (cppobj :> any Arg.t)
     ; (unit       :> any Arg.t)
     ])
  ; ("addRole", sprintf "caml_%s_addRole_cppmeth_wrapper" classname,
     [ (cppobj     :> any Arg.t)
     ; (int        :> any Arg.t)
     ; (bytearray  :> any Arg.t)
     ; (unit       :> any Arg.t)
     ])
  ]

let itemmodel_members =
  let mi = {mi_virt=true;mi_const=true} in
  let wrap ?(i=mi) name xs = (name, xs, i) in

  [ wrap "parent"
      [ (modelindex :> non_cppobj Arg.t)
      ; (modelindex :> non_cppobj Arg.t) ]
  ; wrap "index"
      [ (int        :> non_cppobj Arg.t)
      ; (int        :> non_cppobj Arg.t)
      ; (modelindex :> non_cppobj Arg.t)
      ; (modelindex :> non_cppobj Arg.t) ]
  ; wrap "columnCount"
      [ (modelindex :> non_cppobj Arg.t)
      ; (int        :> non_cppobj Arg.t) ]
  ; wrap "rowCount"
      [ (modelindex :> non_cppobj Arg.t)
      ; (int        :> non_cppobj Arg.t) ]
  ; wrap "hasChildren"
      [ (modelindex :> non_cppobj Arg.t)
      ; (bool       :> non_cppobj Arg.t) ]
  ; wrap "data"
      [ (modelindex :> non_cppobj Arg.t)
      ; (int        :> non_cppobj Arg.t)
      ; (variant    :> non_cppobj Arg.t) ]
  ; wrap "addRole" ~i:{mi_virt=false; mi_const=false}
      [ (qstring    :> non_cppobj Arg.t)
      ; (int        :> non_cppobj Arg.t)
      ; (unit       :> non_cppobj Arg.t) ]
  ]

let gen_itemmodel_stuff ~classname =
  let hndl = FilesMap.find (classname,FilesKey.CSRC) !files in
  let rec rem_cppobj : any Arg.t -> non_cppobj Arg.t option = fun x ->
    match x with
      | Cppobj -> None
      | Unit   -> Some (unit :> non_cppobj Arg.t)
      | Int    -> Some (int  :> non_cppobj Arg.t)
      | Bool   -> Some (bool :> non_cppobj Arg.t)
      | QByteArray  -> Some (bytearray :> non_cppobj Arg.t)
      | QString     -> Some (qstring :> non_cppobj Arg.t)
      | QModelIndex -> Some (modelindex :> non_cppobj Arg.t)
      | QVariant    -> Some (variant :> non_cppobj Arg.t)
      | QList xs    ->
          match (rem_cppobj xs) with
          | None -> None
          | Some y -> Some (qlist (y :> non_cppobj Arg.t))
  in
  let f (methname, stubname, types) =
    (* first type is for this in OCaml *)
    let types = List.tl_exn types in
    let types = List.filter_map ~f:(fun x -> rem_cppobj x) types in
    let types = List.map ~f:wrap_typ_simple types in
    gen_stub_cpp ~options:[`ItemModel] ~classname ~stubname ~methname hndl types
  in
  List.iter ~f (itemmodel_externals ~classname);
  ()
