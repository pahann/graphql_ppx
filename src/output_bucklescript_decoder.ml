open Result_structure
open Schema

open Ast_402
open Asttypes
open Parsetree

let const_str_expr s = Ast_helper.(Exp.constant (Const_string (s, None)))

let string_decoder loc =
  [%expr match Js.Json.decodeString value with
    | None -> raise (Graphql_error ("Expected string, got " ^ (Js.Json.stringify value)))
    | Some value -> (value : string)] [@metaloc loc]

let id_decoder = string_decoder

let float_decoder loc =
  [%expr match Js.Json.decodeNumber value with
    | None -> raise (Graphql_error ("Expected float, got " ^ (Js.Json.stringify value)))
    | Some value -> value] [@metaloc loc]

let int_decoder loc =
  [%expr match Js.Json.decodeNumber value with
    | None -> raise (Graphql_error ("Expected int, got " ^ (Js.Json.stringify value)))
    | Some value -> int_of_float value] [@metaloc loc]

let boolean_decoder loc =
  [%expr match Js.Json.decodeBoolean value with
    | None -> raise (Graphql_error ("Expected boolean, got " ^ (Js.Json.stringify value)))
    | Some value -> value] [@metaloc loc]

let generate_poly_enum_decoder loc enum_meta =
  let enum_match_arms = Ast_helper.(List.map
                                      (fun {evm_name} -> Exp.case 
                                          (Pat.constant (Const_string (evm_name, None)))
                                          (Exp.variant evm_name None))
                                      enum_meta.em_values) in
  let fallback_arm = Ast_helper.(Exp.case
                                   (Pat.any ())
                                   [%expr raise (Graphql_error (
                                       "Unknown enum variant for " ^
                                       [%e const_str_expr enum_meta.em_name] ^
                                       ": " ^ value))]) in
  let match_expr = Ast_helper.(Exp.match_
                                 [%expr value]
                                 (List.concat [enum_match_arms; [fallback_arm]])) in
  let enum_ty = Ast_helper.(
      Typ.variant
        (List.map (fun { evm_name } -> Rtag (evm_name, [], true, [])) enum_meta.em_values)
        Closed None) [@metaloc loc]
  in
  [%expr match Js.Json.decodeString value with 
    | None -> raise (Graphql_error (
        "Expected enum value for " ^
        [%e const_str_expr enum_meta.em_name] ^
        ", got " ^ (Js.Json.stringify value)))
    | Some value -> ([%e match_expr]: [%t enum_ty])]

let generate_solo_fragment_spread loc name =
  let ident = Ast_helper.Exp.ident { loc = loc; txt = Longident.parse (name ^ ".parse") } in
  [%expr [%e ident] value]

let generate_error loc message =
  let ext = Ast_mapper.extension_of_error (Location.error ~loc message) in
  [%expr let _value = value in [%e Ast_helper.Exp.extension ~loc ext]]

let rec generate_decoder = function
  | Res_nullable (loc, inner) -> generate_nullable_decoder loc inner
  | Res_array (loc, inner) -> generate_array_decoder loc inner
  | Res_id loc -> id_decoder loc
  | Res_string loc -> string_decoder loc
  | Res_int loc -> int_decoder loc
  | Res_float loc -> float_decoder loc
  | Res_boolean loc -> boolean_decoder loc
  | Res_raw_scalar loc -> [%expr value]
  | Res_poly_enum (loc, enum_meta) -> generate_poly_enum_decoder loc enum_meta
  | Res_custom_decoder (loc, ident, inner) -> generate_custom_decoder loc ident inner
  | Res_record (loc, name, fields) -> generate_record_decoder loc name fields
  | Res_object (loc, name, fields) -> generate_object_decoder loc name fields
  | Res_poly_variant_selection_set (loc, name, fields) -> generate_poly_variant_selection_set loc name fields
  | Res_poly_variant_union (loc, name, fragments, exhaustive) -> generate_poly_variant_union loc name fragments exhaustive
  | Res_solo_fragment_spread (loc, name) -> generate_solo_fragment_spread loc name
  | Res_error (loc, message) -> generate_error loc message

and generate_nullable_decoder loc inner =
  [%expr match Js.Json.decodeNull value with
    | None -> Some [%e generate_decoder inner]
    | Some _ -> None] [@metaloc loc]

and generate_array_decoder loc inner =
  [%expr match Js.Json.decodeArray value with
    | None -> raise (Graphql_error ("Expected array, got " ^ (Js.Json.stringify value)))
    | Some value -> Js.Array.map (fun value -> [%e generate_decoder inner]) value] [@metaloc loc]

and generate_custom_decoder loc ident inner =
  let fn_expr = Ast_helper.(Exp.ident
                              { loc = Location.none; txt = Longident.parse ident }) in
  [%expr [%e fn_expr] ([%e generate_decoder inner])] [@metaloc loc]


and generate_record_decoder loc name fields =
  (*
    Given a selection set, this function first generates the resolvers,
    binding the results to individual local variables. It then generates
    a record containing each field bound to the corresponding variable.

    While this might seem a bit convoluted, it lets us wrap the record in
    a [%bs.obj ] extension to generate a JavaScript object without having
    to worry about the record-in-javascript-object problem that BuckleScript has.

    As an example, a selection set like "{ f1 f2 f3 }" will result in
    let (field_f1, field_f2, field_f3) = (
      match Js.Dict.get value "f1" with ... end
      match Js.Dict.get value "f2" with ... end
      match Js.Dict.get value "f3" with ... end
    ) in { f1 = field_f1; f2 = field_f2; f3 = field_f3 }
  *)

  let field_name_tuple_pattern = Ast_helper.(
      fields
      |> List.map (fun (field, _) -> Pat.var { loc = Location.none; txt = "field_" ^ field })
      |> Pat.tuple) in

  let field_decoder_tuple = Ast_helper.(
      fields
      |> List.map (fun (field, inner) -> 
          [%expr match Js.Dict.get value [%e const_str_expr field] with
            | None -> raise (Graphql_error (
                "Field " ^ [%e const_str_expr field] ^
                " on type " ^ [%e const_str_expr name] ^ " is missing"))
            | Some value -> [%e generate_decoder inner]])
      |> Exp.tuple) in

  let record_fields = Ast_helper.(
      fields
      |> List.map (fun (field, _) ->
          (
            { Location.loc = Location.none; txt = Longident.Lident field}, 
            Exp.ident { loc = Location.none; txt = Longident.Lident ("field_" ^ field) }))) in
  let record = Ast_helper.Exp.record record_fields None in

  [%expr match Js.Json.decodeObject value with
    | None -> raise (Graphql_error (
        "Expected object of type " ^
        [%e const_str_expr name] ^
        ", got " ^ (Js.Json.stringify value)))
    | Some value ->
      let [%p field_name_tuple_pattern] = [%e field_decoder_tuple]
      in [%e record]] [@metaloc loc]

and generate_object_decoder loc name fields =
  let ctor_result_type = (List.mapi 
                            (fun i (key, _) -> (key, [], Ast_helper.Typ.var ("a" ^ (string_of_int i))))
                            fields)
  in
  let rec make_obj_constructor_fn i = function
    | [] -> Ast_helper.Typ.arrow "" (Ast_helper.Typ.constr { txt = Longident.Lident "unit"; loc = Location.none} [])
              (Ast_helper.Typ.constr { txt = Longident.parse "Js.t"; loc = Location.none} [
                  (Ast_helper.Typ.object_
                     ctor_result_type
                     Closed)
                ])
    | (key, _) :: next -> Ast_helper.Typ.arrow key (Ast_helper.Typ.var ("a" ^ (string_of_int i)))
                            (make_obj_constructor_fn (i+1) next) in
  [%expr match Js.Json.decodeObject value with
    | None -> raise (Graphql_error "Object is not a value")
    | Some value ->
      [%e
        Ast_helper.Exp.letmodule {txt = "GQL"; loc = Location.none} (Ast_helper.Mod.structure [
            Ast_helper.Str.primitive {
              pval_name = {txt = "make_obj"; loc = Location.none};
              pval_type = make_obj_constructor_fn 0 fields;
              pval_prim = [""];
              pval_attributes = [({txt = "bs.obj"; loc = Location.none}, PStr [])];
              pval_loc = Location.none;
            }
          ])
          (Ast_helper.Exp.apply (Ast_helper.Exp.ident { txt = Longident.parse "GQL.make_obj"; loc = Location.none})
             (List.append
                (List.map (fun (key, inner) -> 
                     (
                       key,
                       [%expr match Js.Dict.get value [%e const_str_expr key] with
                         | None -> raise (Graphql_error ("Field " ^ [%e const_str_expr key] ^ " on type " ^ [%e const_str_expr name] ^ " is missing"))
                         | Some value -> [%e generate_decoder inner]
                       ]
                     )) fields)
                [("", Ast_helper.Exp.construct { txt = Longident.Lident "()"; loc = Location.none} None)]
             ))
      ]
  ] [@metaloc loc]

and generate_poly_variant_selection_set loc name fields =
  let rec generator_loop = function
    | (field, inner) :: next ->
      let variant_decoder = Ast_helper.(Exp.variant
                                          (String.capitalize field)
                                          (Some (generate_decoder inner))) in
      [%expr match Js.Dict.get value [%e const_str_expr field] with
        | None -> raise (Graphql_error (
            "Field " ^ [%e const_str_expr field] ^
            " on type " ^ [%e const_str_expr name] ^ " is missing"))
        | Some temp -> match Js.Json.decodeNull temp with
          | None -> let value = temp in [%e variant_decoder]
          | Some _ -> [%e generator_loop next]]
    | [] -> [%expr raise (Graphql_error (
        "All fields on variant selection set on type " ^ 
        [%e const_str_expr name] ^
        " were null"))] in
  let variant_type = Ast_helper.(
      Typ.variant
        (List.map (fun (name, _) -> Rtag (name, [], false, [{ ptyp_desc = Ptyp_any; ptyp_attributes = []; ptyp_loc = Location.none }])) fields)
        Closed None) in
  [%expr match Js.Json.decodeObject value with
    | None -> raise (Graphql_error ("Expected type " ^ [%e const_str_expr name] ^ " to be an object"))
    | Some value -> ([%e generator_loop fields]: [%t variant_type])] [@metaloc loc]

and generate_poly_variant_union loc name fragments exhaustive_flag =
  let fragment_cases = Ast_helper.(
      fragments
      |> List.map (fun (type_name, inner) -> 
          let name_pattern = Pat.constant (Const_string (type_name, None)) in
          let variant = Ast_helper.(Exp.variant type_name (Some (generate_decoder inner))) in
          Exp.case name_pattern variant)) in
  let fallback_case, fallback_case_ty = Ast_helper.(match exhaustive_flag with
      | Result_structure.Exhaustive ->
        (Exp.case
           (Pat.var { loc = Location.none; txt = "typename" })
           [%expr raise (Graphql_error (
               "Union " ^ [%e const_str_expr name] ^
               " returned unknown type " ^ typename))],
         [ ])
      | Nonexhaustive -> 
        (Exp.case (Pat.any ()) [%expr `Nonexhaustive]), [Rtag ("Nonexhaustive", [], true, [])]) in
  let fragment_case_tys = List.map
      (fun (name, _) -> Rtag (name, [], false, [{ ptyp_desc = Ptyp_any; ptyp_attributes = []; ptyp_loc = Location.none }])) 
      fragments in
  let union_ty = Ast_helper.(Typ.variant (List.concat [ fallback_case_ty; fragment_case_tys ]) Closed None) in
  let typename_matcher = Ast_helper.(Exp.match_
                                       [%expr typename]
                                       (List.concat [ fragment_cases; [ fallback_case ]])) in
  [%expr
    match Js.Json.decodeObject value with
    | None -> raise (Graphql_error ("Expected union " ^ [%e const_str_expr name] ^ " to be an object, got " ^ (Js.Json.stringify value)))
    | Some typename_obj -> match Js.Dict.get typename_obj "__typename" with
      | None -> raise (Graphql_error (
          "Union " ^ [%e const_str_expr name] ^
          " is missing the __typename field"))
      | Some typename -> match Js.Json.decodeString typename with
        | None -> raise (Graphql_error (
            "Union " ^ [%e const_str_expr name] ^
            " has a __typename field that is not a string"))
        | Some typename -> ([%e typename_matcher]: [%t union_ty])] [@metaloc loc]
