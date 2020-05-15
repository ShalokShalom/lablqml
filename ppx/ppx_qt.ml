open Base
open Printf
open PpxQtCfg
open Gencpp

exception ErrorMsg of string * Location.t

let () =
  Location.register_error_of_exn (fun exn ->
    match exn with
    | ErrorMsg (msg,loc) -> Some (Location.error ~loc msg)
    | _ -> None)

open Ppxlib
open Ppxlib.Ast_builder.Default


let rec has_attr name: Parsetree.attributes -> bool = function
  | [] -> false
  | {attr_name= {txt;_}; _ } :: _ when String.equal txt name  -> true
  | _ :: xs -> has_attr name xs

let find_attr_exn ~name xs =
  List.find_map_exn xs ~f:(fun {attr_name= {txt;_}; attr_payload } ->
    if String.equal txt name
    then Some attr_payload
    else None)

let type_suits_prop ty =
  let open Base.Result in
  match ty with
  | [%type: int]       -> return Arg.Int
  | [%type: bool]      -> return Arg.Bool
  | [%type: string]    -> return Arg.QString
  | [%type: Variant.t]
  | [%type: QVariant.t] -> return Arg.QVariant
  | [%type: unit] -> fail "property can't have type 'unit'"
  | {ptyp_desc = Ptyp_constr ({txt=Lident x; _},[]); _ } ->
      fail (sprintf "Don't know what to do with '%s'" x)
  | _ -> fail "Type is unknown"

let make_coretyp ~loc txt = Ast_helper.Typ.constr ~loc ({txt; loc}) []
let cppobj_coretyp loc = make_coretyp ~loc (Lident "cppobj")
let unit_coretyp loc = make_coretyp ~loc (Lident "unit")
let int_coretyp loc = make_coretyp ~loc (Lident "int")
let string_coretyp loc = make_coretyp ~loc (Lident "string")

let make_store_func ~loc ~classname : structure_item =
  let pval_name = {txt="store"; loc} in
  let pval_prim = [sprintf "caml_store_value_in_%s" classname] in
  let pval_type = Ast_helper.Typ.(arrow Nolabel
                                        (cppobj_coretyp loc)
                                        (arrow Nolabel
                                               (object_ ~loc [] Open)
                                               (constr ~loc {txt=Lident "unit"; loc} [] ) ) )
  in
  let pstr_desc = Pstr_primitive {pval_name; pval_type; pval_prim; pval_attributes=[];
                                  pval_loc=loc } in
  { pstr_desc; pstr_loc=loc }

let make_stub_general ~loc ~typnames ~name ~stub_name =
  let pval_prim = [stub_name] in
  let pval_name = {txt=name; loc} in

  let rec helper = function
    | [] -> assert false
    | [txt] ->   Ast_helper.Typ.constr ~loc {txt; loc} []
    | txt::xs -> Ast_helper.Typ.(arrow Nolabel (constr ~loc {txt; loc} []) (helper xs) )
  in
  let pval_type = helper typnames in
  let pstr_desc = Pstr_primitive {pval_name; pval_type; pval_prim; pval_attributes=[];
                                  pval_loc=loc } in
  { pstr_desc; pstr_loc=loc }

let make_creator ~loc ~classname =
  let pval_prim = [sprintf "caml_create_%s" classname] in
  let pval_name = {txt=sprintf "create_%s" classname; loc} in

  let pval_type =
    Ast_helper.Typ.(arrow Nolabel (constr ~loc {txt=Lident "unit"; loc} [])
                          (var ~loc "a") )
  in
  let pstr_desc = Pstr_primitive {pval_name; pval_type; pval_prim; pval_attributes=[];
                                  pval_loc=loc } in
  { pstr_desc; pstr_loc=loc }


let make_stub_for_signal ~classname ~loc ~typ name : structure_item =
(*  let open Ast_helper in*)
  let pval_name = {txt="stub_"^name; loc} in
  let pval_prim = [sprintf "caml_%s_%s_cppmeth_wrapper" classname name] in
  let pval_type = Ast_helper.Typ.(arrow Nolabel
                                        (cppobj_coretyp loc)
                                        (arrow Nolabel typ
                                               (constr ~loc {txt=Lident "unit"; loc} [] ) ) )
  in
  let pstr_desc = Pstr_primitive {pval_name; pval_type; pval_prim; pval_attributes=[];
                                  pval_loc=loc } in
  { pstr_desc; pstr_loc=loc }

let make_virt_meth ~loc ~name xs =
  let open Ast_helper in
  let rec helper = function
    | [] -> assert false
    | [t] ->   Typ.constr ~loc {txt=Gencpp.ocaml_ast_of_typ t; loc} []
    | t::xs -> Typ.(arrow Nolabel
                          (constr ~loc {txt=Gencpp.ocaml_ast_of_typ t; loc} [])
                          (helper xs) )
  in
  let typ = helper xs in
  Cf.method_ (Located.mk name ~loc) Public (Cfk_virtual typ)

let mkloc x loc = Located.mk ~loc x

let make_initializer ~loc : class_field =
(*  let pexp_desc = Ast_helper.Exp.(
    apply (ident (mkloc (Lident "store") loc))
          [ (Nolabel, ident (mkloc (Lident "cppobj") loc))
          ; (Nolabel, ident (mkloc (Lident "self") loc))
          ]
          )
  in (* TODO: *)*)
  let pcf_desc = Pcf_initializer [%expr store cppobj self ] in
  { pcf_desc; pcf_loc=loc; pcf_attributes=[] }

let make_handler_meth ~loc : class_field =
  let e = [%expr cppobj ] in
  Ast_helper.(Cf.method_ (Located.mk "handler" ~loc) Public (Cfk_concrete (Fresh,e)  ) )

(* return list of pairs. 1st is argument label. 2nd is actual type *)
let eval_meth_typ_gen t =
  let rec parse_one t = match t.ptyp_desc with
    | Ptyp_constr (({txt=Lident "list"  ;_}),[typarg]) -> Arg.QList (parse_one typarg)
    | Ptyp_constr (({txt=Lident "string";_}),_) -> Arg.QString
    | Ptyp_constr (({txt=Lident "unit"  ;_}),_) -> Arg.Unit
    | Ptyp_constr (({txt=Lident "int"   ;_}),_) -> Arg.Int
    | Ptyp_constr (({txt=Lident "variant";_}),_)
    | Ptyp_constr (({txt=Ldot (Lident "Variant", "t");_}),_)
    | Ptyp_constr (({txt=Ldot (Lident "QVariant","t");_}),_) -> Arg.QVariant
    | _ -> raise @@ ErrorMsg ("can't eval type", t.ptyp_loc)
  in
  let rec helper t =
    match t.ptyp_desc with
    | Ptyp_arrow (name,l,r) -> [name, parse_one l] @ (helper r)
    | _ -> [Nolabel, parse_one t]
  in
  helper t

let eval_meth_typ t = List.map ~f:snd (eval_meth_typ_gen t)
let eval_signal_typ = eval_meth_typ_gen

let check_meth_typ ~loc _xs =
  let _ = loc in
  (* TODO: some checks like unit type should be at the end of list *)
  (* TODO: check that modelindexes are not used without QAbstractItemModel base *)
  true

let wrap_meth ~classname ?(options=[]) (({txt=methname; loc},_,kind) as m) =
  match kind with
  | Cfk_concrete _ -> raise @@ ErrorMsg ("Qt methods should be marked as virtual", loc)
  | Cfk_virtual typ -> begin
     let meth_typ = eval_meth_typ typ in
     if not (check_meth_typ ~loc meth_typ)
     then raise @@ ErrorMsg (sprintf "Method '%s' has wrong type" methname, loc);
     let () =
      if PpxQtCfg.config.gencpp
      then
        let options =
          if Options.is_itemmodel options then [`ItemModel] else []
        in
        Gencpp.gen_meth ~options ~classname ~methname (meth_typ :> Arg.non_cppobj Arg.t list)
     in
     [Pcf_method m]
  end

(* in 4.03 definition have changed from string to Ast_types.arg_label *)
let oldify_arg_label = function
  | Nolabel -> ""
  | Labelled s -> s
  | Optional s -> s

let wrap_class_decl ?(destdir=".") ~attributes loc (ci: class_declaration) =
  (* print_endline "wrap_class_type_decl on class type markend with `qtclass`"; *)
  let classname = ci.pci_name.txt in
  let options =
    List.concat
      [ if has_attr "itemmodel"    attributes then [`ItemModel] else []
      ; if has_attr "instantiable" attributes then [`Instantiable] else []
      ]
  in
  if PpxQtCfg.config.gencpp then Gencpp.open_files ~options ~ext:PpxQtCfg.config.ext ~destdir ~classname;

  let clas_sig = match ci.pci_expr.pcl_desc with
    | Pcl_structure s -> s
    |  _    -> raise @@ ErrorMsg ("Qt class signature should be structure of class", ci.pci_loc)
  in
  let fields: class_field list = clas_sig.pcstr_fields in

  let heading = ref [] in
  Ref.replace heading (fun xs -> (make_store_func ~classname ~loc) :: xs);
(*  Ref.append ~set:heading (make_store_func ~classname ~loc);*)

  let wrap_signal ~options ~classname (({txt=signalname; loc},_,kind) as _m) =
    let _ =  options in
    match kind with
    | Cfk_concrete _ ->
       raise @@ ErrorMsg ("We can generate prop methods for virtuals only", loc)
    | Cfk_virtual core_typ ->
       (* stub which will be called by OCaml meth*)
       let external_stub =
         let pval_name = {txt="stub_"^signalname; loc} in
         let pval_prim = [sprintf "caml_%s_%s_emitter_wrapper" classname signalname] in
         let pval_type = Ast_helper.Typ.(arrow Nolabel
                                               (cppobj_coretyp loc)
                                               core_typ)
         in
         let pstr_desc = Pstr_primitive {pval_name; pval_type; pval_prim; pval_attributes=[];
                                         pval_loc=loc } in
         { pstr_desc; pstr_loc=loc }
       in
       Gencpp.ref_append ~set:heading external_stub;

       (* C++ stub *)
       let types = eval_signal_typ core_typ in
       let (args,res) = List.(drop_last_exn types, last_exn types) in
       if Stdlib.(snd res <> Gencpp.Arg.Unit)
       then raise @@ ErrorMsg ("Result type for signal should be unit", loc);

       assert Stdlib.(fst res = Nolabel);
       (* last argument always will be without a label, isn't it? *)

       if List.exists ~f:(fun (label,_) -> Stdlib.(=) label Nolabel) args
       then raise @@ ErrorMsg ("All arguments should have a label", loc);

       if config.gencpp
       then Gencpp.gen_signal ~classname ~signalname @@
            List.map ~f:(fun (l,x) -> (oldify_arg_label l, (x :> Arg.non_cppobj Arg.t))) args;
       (* OCaml meth *)
       let open Ast_helper in
       let e = Exp.(poly (apply
                            (ident (Located.mk ~loc (Lident ("stub_"^signalname))) )
                            [Nolabel, [%expr self#handler]
                            ]
                         )
                         None) in

       [ (Cf.method_ (Located.mk ~loc ("emit_" ^ signalname))
                     Public (Cfk_concrete (Fresh,e)) ).pcf_desc
       ]
  in

  let wrap_prop ~classname (loc,flag,kind) =
    let propname = loc.txt in
    let loc = loc.loc in
    match kind with
    | Cfk_concrete _ ->
       raise @@ ErrorMsg ("We can generate prop methods for virtuals only", loc)
    | Cfk_virtual core_typ -> begin
       match type_suits_prop core_typ with
       | Ok typ ->
          if config.gencpp then Gencpp.gen_prop ~classname ~propname typ;
          let signal_name = Names.signal_of_prop propname in
          ref_append ~set:heading (make_stub_for_signal ~classname ~loc ~typ:core_typ signal_name);
          let open Ast_helper in
          let e = Exp.(poly (apply
                               (ident (mkloc (Lident ("stub_"^signal_name)) loc) )
                               [Nolabel, [%expr self#handler]
                               ]
                            )
                            None) in

          [ (Cf.method_ (mkloc ("emit_" ^ signal_name) loc)
                      Public (Cfk_concrete (Fresh,e)) ).pcf_desc
          ; Pcf_method (Located.mk ~loc (Gencpp.Names.getter_of_prop propname),
                        flag,
                        Cfk_virtual Ast_helper.Typ.(arrow Nolabel (unit_coretyp loc) core_typ) )
          ]
       | Error msg ->
          raise @@ ErrorMsg (sprintf "Can't wrap property '%s': %s" propname msg, loc)
    end
  in
  let wrap_field (f_desc: class_field) : class_field list =
    let ans = match f_desc.pcf_desc with
      | Pcf_method m  when has_attr "qtmeth" f_desc.pcf_attributes ->
         wrap_meth ~options ~classname m
      | Pcf_method m  when has_attr "qtsignal" f_desc.pcf_attributes ->
         wrap_signal ~options ~classname m
      | Pcf_method m  when has_attr "qtprop" f_desc.pcf_attributes ->
         wrap_prop ~classname m
      | _ -> []
    in
    List.map ~f:(fun ans -> { f_desc with pcf_desc=ans }) ans
  in
  let itemmodel_meths =  if has_attr "itemmodel" attributes then (
    let f (methname, meth_typ, minfo) =
      (* printf "Generating itemmodel-specific meth: '%s'\n" methname; *)
      if config.gencpp then Gencpp.gen_meth ~classname ~methname ~minfo meth_typ
    in
    if config.gencpp then List.iter ~f Gencpp.itemmodel_members;
    (* now add some OCaml code *)

    let f (name,stub_name,xs) =
(*      let xs = (xs :> Gencpp.meth_typ_item list) in*)
      let typnames = List.map xs ~f:Gencpp.ocaml_ast_of_typ in
      ref_append ~set:heading @@ make_stub_general ~loc ~typnames ~name:("stub_"^name) ~stub_name;
      (*let stubname: string  = sprintf "caml_%s_%s_cppmeth_wrapper" classname name in*)
      (*
      gen_stub_cpp ~classname ~methname:name ~stubname
                   hndl
                   [ ((typ   :> meth_typ_item), {ai_ref=false;ai_const=false})
                   ; ((`unit :> meth_typ_item), {ai_ref=false;ai_const=false})
                   ]; *)
      ()
    in
    List.iter (Gencpp.itemmodel_externals ~classname) ~f;
    let () = if config.gencpp then Gencpp.gen_itemmodel_stuff ~classname in

    let add_role_stub =
      let pval_name = {txt="add_role"; loc} in
      let pval_prim = [sprintf "caml_%s_%s_cppmeth_wrapper" classname "addRole"] in
      let pval_type = Ast_helper.Typ.(arrow Nolabel (var "a")
                                            (arrow Nolabel (int_coretyp loc)
                                                   (arrow Nolabel (string_coretyp loc)
                                                          (unit_coretyp loc)
                                                   )
                                            )
                      )
      in
      let pstr_desc = Pstr_primitive {pval_name; pval_type; pval_prim; pval_attributes=[];
                                      pval_loc=loc } in
      { pstr_desc; pstr_loc=loc }
    in
    ref_append add_role_stub ~set:heading;
    let f name =
      let open Ast_helper in
      let e = Exp.(poly (apply
                           (ident (mkloc (Lident ("stub_"^name)) loc) )
                           [(Nolabel,ident (mkloc (Lident "cppobj") loc) )]
                        ) None
              )
      in
      (Cf.method_ (mkloc name loc) Public (Cfk_concrete (Fresh,e)) )
    in
    let emitters =
      List.map ~f [ "dataChanged"; "beginInsertRows"; "endInsertRows"; "beginRemoveRows"
                  ; "endRemoveRows" ]
    in
    let virtuals =
      [ make_virt_meth [ Arg.QModelIndex; Arg.QModelIndex ] ~loc ~name:"parent"
      ; make_virt_meth [ Arg.Int; Arg.Int; Arg.QModelIndex; Arg.QModelIndex ] ~loc ~name:"index"
      ; make_virt_meth [ Arg.QModelIndex; Arg.Int ] ~loc ~name:"columnCount"
      ; make_virt_meth [ Arg.QModelIndex; Arg.Int ] ~loc ~name:"rowCount"
      ; make_virt_meth [ Arg.QModelIndex; Arg.Bool ] ~loc ~name:"hasChildren"
      ; make_virt_meth [ Arg.QModelIndex; Arg.Int; Arg.QVariant ] ~loc ~name:"data"
      ]
    in
    emitters @ virtuals
  ) else []
  in
  let new_fields = (fields |> List.map ~f:wrap_field  |> List.concat) @ itemmodel_meths in

  let new_fields = (make_initializer ~loc) :: (make_handler_meth ~loc) :: new_fields in
  let new_desc = Pcl_structure { pcstr_fields = new_fields;
                                 pcstr_self = Ast_helper.Pat.var (mkloc "self" loc) } in
  let new_expr = {ci.pci_expr with pcl_desc = new_desc } in
  let new_desc2 =
    Pcl_fun (Nolabel, None, Ast_helper.Pat.var (mkloc "cppobj" loc), new_expr)
  in
  let new_expr2 = {new_expr with pcl_desc = new_desc2 } in

  let ans = { pstr_desc=Pstr_class [{{ci with pci_expr=new_expr2} with pci_attributes=[]}]
            ; pstr_loc=loc } in
  let creator = make_creator ~loc ~classname in
  if config.gencpp then Gencpp.close_files ~options;
  !heading @ [ans; creator]

let wrap_module_decl ~loc me info =
  []

let () =
  Ppxlib.Driver.register_transformation
      ~impl:(fun ss ->
      let m = object(self)
        inherit Ast_traverse.map as super
        method! structure ss = (* TODO: Maybe we don't need this *)
          List.concat @@ List.map ~f:(self#do_structure_item) ss

        method do_structure_item si =
          match si.pstr_desc with
          | Pstr_class [cinfo] when has_attr "qtclass" cinfo.pci_attributes ->
              Ast_helper.with_default_loc si.pstr_loc (fun () ->
                wrap_class_decl ~destdir:config.destdir ~attributes:cinfo.pci_attributes
                                si.pstr_loc cinfo
              )
          | Pstr_module {pmb_expr; pmb_attributes}  when has_attr "qml" pmb_attributes ->
              begin
                match find_attr_exn pmb_attributes ~name:"qml" with
                | PStr [{pstr_desc= Pstr_eval (e,_) }] -> begin
                    match Testdemo.parse_singleton e  with
                      | None -> raise (ErrorMsg ("bad attribute", si.pstr_loc))
                      | Some info ->
                          wrap_module_decl ~loc:si.pstr_loc pmb_expr info
                    end
(*                    [super#structure_item si]*)
                | _ -> raise (ErrorMsg ("bad attribute", si.pstr_loc))
              end

          | _ -> [super#structure_item si]
      end in
    m#structure ss
  )
  "ppx_qt"

