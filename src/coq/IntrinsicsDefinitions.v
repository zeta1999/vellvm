From Coq Require Import
     ZArith List String.

From ExtLib Require Import
     Structures.Monads
     Programming.Eqv
     Data.String.

From Vir Require Import
     LLVMEvents
     LLVMAst
     Error
     Coqlib
     Numeric.Integers
     Numeric.Floats.

From ITree Require Import
     ITree.

From Flocq.IEEE754 Require Import
     Binary
     Bits.

Import MonadNotation.
Import EqvNotation.
Import ListNotations.

Set Implicit Arguments.
Set Contextual Implicit.

Definition fabs_32_decl: declaration typ :=
  {|
    dc_name        := Name "llvm.fabs.f32";
    dc_type        := TYPE_Function TYPE_Float [TYPE_Float] ;
    dc_param_attrs := ([], [[]]);
    dc_linkage     := None ;
    dc_visibility  := None ;
    dc_dll_storage := None ;
    dc_cconv       := None ;
    dc_attrs       := [] ;
    dc_section     := None ;
    dc_align       := None ;
    dc_gc          := None
  |}.


Definition fabs_64_decl: declaration typ :=
  {|
    dc_name        := Name "llvm.fabs.f64";
    dc_type        := TYPE_Function TYPE_Double [TYPE_Double] ;
    dc_param_attrs := ([], [[]]);
    dc_linkage     := None ;
    dc_visibility  := None ;
    dc_dll_storage := None ;
    dc_cconv       := None ;
    dc_attrs       := [] ;
    dc_section     := None ;
    dc_align       := None ;
    dc_gc          := None
  |}.

Definition memcpy_8_decl: declaration typ :=
  let pt := TYPE_Pointer (TYPE_I 8%Z) in
  let i32 := TYPE_I 32%Z in
  let i1 := TYPE_I 1%Z in
  {|
    dc_name        := Name "llvm.memcpy.p0i8.p0i8.i32";
    dc_type        := TYPE_Function TYPE_Void [pt; pt; i32; i32; i1] ;
    dc_param_attrs := ([], [[];[];[];[];[]]);
    dc_linkage     := None ;
    dc_visibility  := None ;
    dc_dll_storage := None ;
    dc_cconv       := None ;
    dc_attrs       := [] ;
    dc_section     := None ;
    dc_align       := None ;
    dc_gc          := None
  |}.

Definition maxnum_64_decl: declaration typ :=
  {|
    dc_name        := Name "llvm.maxnum.f64";
    dc_type        := TYPE_Function TYPE_Double [TYPE_Double;TYPE_Double] ;
    dc_param_attrs := ([], [[];[]]);
    dc_linkage     := None ;
    dc_visibility  := None ;
    dc_dll_storage := None ;
    dc_cconv       := None ;
    dc_attrs       := [] ;
    dc_section     := None ;
    dc_align       := None ;
    dc_gc          := None
  |}.

Definition minimum_64_decl: declaration typ :=
  {|
    dc_name        := Name "llvm.minimum.f64";
    dc_type        := TYPE_Function TYPE_Double [TYPE_Double;TYPE_Double] ;
    dc_param_attrs := ([], [[];[]]);
    dc_linkage     := None ;
    dc_visibility  := None ;
    dc_dll_storage := None ;
    dc_cconv       := None ;
    dc_attrs       := [] ;
    dc_section     := None ;
    dc_align       := None ;
    dc_gc          := None
  |}.

Definition maxnum_32_decl: declaration typ :=
  {|
    dc_name        := Name "llvm.maxnum.f32";
    dc_type        := TYPE_Function TYPE_Float [TYPE_Float;TYPE_Float] ;
    dc_param_attrs := ([], [[];[]]);
    dc_linkage     := None ;
    dc_visibility  := None ;
    dc_dll_storage := None ;
    dc_cconv       := None ;
    dc_attrs       := [] ;
    dc_section     := None ;
    dc_align       := None ;
    dc_gc          := None
  |}.

Definition minimum_32_decl: declaration typ :=
  {|
    dc_name        := Name "minimum.f32";
    dc_type        := TYPE_Function TYPE_Float [TYPE_Float;TYPE_Float] ;
    dc_param_attrs := ([], [[];[]]);
    dc_linkage     := None ;
    dc_visibility  := None ;
    dc_dll_storage := None ;
    dc_cconv       := None ;
    dc_attrs       := [] ;
    dc_section     := None ;
    dc_align       := None ;
    dc_gc          := None
  |}.

(* This may seem to overlap with `defined_intrinsics`, but there are few differences:
   1. This one is defined outside of the module and could be used at the LLVM AST generation stage without yet specifying memory model.
   2. It includes declarations for built-in memory-dependent intrinisics such as `memcpy`.
 *)
Definition defined_intrinsics_decls :=
  [ fabs_32_decl; fabs_64_decl; maxnum_32_decl ; maxnum_64_decl; minimum_32_decl; minimum_64_decl; memcpy_8_decl ].

(* This functor module provides a way to (extensibly) add the semantic behavior
   for intrinsics defined outside of the core Vellvm operational semantics.

   Internally, invocation of an intrinsic looks no different than that of an
   external function call, so each LLVM intrinsic instruction should produce
   a Call effect.

   Each intrinsic is identified by its name (a string) and its denotation is
   given by a function from a list of dynamic values to a dynamic value (or
   possibly an error).

   NOTE: The intrinsics that can be defined at this layer of the semantics
   cannot affect the core interpreter state or the memory model.  This layer is
   useful for implementing "pure value" intrinsics like floating point
   operations, etc.  Also note that such intrinsics cannot themselves generate
   any other effects.

*)

Module Make(A:MemoryAddress.ADDRESS)(LLVMIO: LLVM_INTERACTIONS(A)).
  Open Scope string_scope.

  Import LLVMIO.
  Import DV.
  Definition semantic_function := (list dvalue) -> err dvalue.
  Definition intrinsic_definitions := list (declaration typ * semantic_function).
  Definition llvm_fabs_f32 : semantic_function :=
    fun args =>
      match args with
      | [DVALUE_Float d] => ret (DVALUE_Float (b32_abs d))
      | _ => failwith "llvm_fabs_f64 got incorrect / ill-typed intputs"
      end.
  Definition llvm_fabs_f64 : semantic_function :=
    fun args =>
      match args with
      | [DVALUE_Double d] => ret (DVALUE_Double (b64_abs d))
      | _ => failwith "llvm_fabs_f64 got incorrect / ill-typed intputs"
      end.


  Definition Float_maxnum (a b: float): float :=
    match a, b with
    | B754_nan _ _ _, _ | _, B754_nan _ _ _ => build_nan _ _ (binop_nan_pl64 a b)
    | _, _ =>
      if Float.cmp Clt a b then b else a
    end.

  Definition Float32_maxnum (a b: float32): float32 :=
    match a, b with
    | B754_nan _ _ _, _ | _, B754_nan _ _ _ => build_nan _ _ (binop_nan_pl32 a b)
    | _, _ =>
      if Float32.cmp Clt a b then b else a
    end.

  Definition llvm_maxnum_f64 : semantic_function :=
    fun args =>
      match args with
      | [DVALUE_Double a; DVALUE_Double b] => ret (DVALUE_Double (Float_maxnum a b))
      | _ => failwith "llvm_maxnum_f64 got incorrect / ill-typed intputs"
      end.

  Definition llvm_maxnum_f32 : semantic_function :=
    fun args =>
      match args with
      | [DVALUE_Float a; DVALUE_Float b] => ret (DVALUE_Float (Float32_maxnum a b))
      | _ => failwith "llvm_maxnum_f32 got incorrect / ill-typed intputs"
      end.

  Definition Float_minimum (a b: float): float :=
    match a, b with
    | B754_nan _ _ _, _ | _, B754_nan _ _ _ => build_nan _ _ (binop_nan_pl64 a b)
    | _, _ =>
      if Float.cmp Clt a b then a else b
    end.

  Definition Float32_minimum (a b: float32): float32 :=
    match a, b with
    | B754_nan _ _ _, _ | _, B754_nan _ _ _ => build_nan _ _ (binop_nan_pl32 a b)
    | _, _ =>
      if Float32.cmp Clt a b then a else b
    end.

  Definition llvm_minimum_f64 : semantic_function :=
    fun args =>
      match args with
      | [DVALUE_Double a; DVALUE_Double b] => ret (DVALUE_Double (Float_minimum a b))
      | _ => failwith "llvm_minimum_f64 got incorrect / ill-typed intputs"
      end.

  Definition llvm_minimum_f32 : semantic_function :=
    fun args =>
      match args with
      | [DVALUE_Float a; DVALUE_Float b] => ret (DVALUE_Float (Float32_minimum a b))
      | _ => failwith "llvm_minimum_f32 got incorrect / ill-typed intputs"
      end.

  (* Clients of Vellvm can register the names of their own intrinsics
     definitions here. *)
  Definition defined_intrinsics : intrinsic_definitions :=
    [ (fabs_32_decl, llvm_fabs_f32) ;
    (fabs_64_decl, llvm_fabs_f64) ;
    (maxnum_32_decl , llvm_maxnum_f32) ;
    (maxnum_64_decl , llvm_maxnum_f64);
    (minimum_32_decl, llvm_minimum_f32);
    (minimum_64_decl, llvm_minimum_f64)
    ].

  (* SAZ: TODO: it could be nice to provide a more general/modular way to "lift"
     primitive functions into intrinsics. *)

>>>>>>> master

End Make.
