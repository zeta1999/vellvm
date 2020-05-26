(* -------------------------------------------------------------------------- *
 *                     Vellvm - the Verified LLVM project                     *
 *                                                                            *
 *     Copyright (c) 2018 Steve Zdancewic <stevez@cis.upenn.edu>              *
 *                                                                            *
 *   This file is distributed under the terms of the GNU General Public       *
 *   License as published by the Free Software Foundation, either version     *
 *   3 of the License, or (at your option) any later version.                 *
 ---------------------------------------------------------------------------- *)

(* begin hide *)
From Coq Require Import
     Morphisms ZArith List String Omega
     FSets.FMapAVL
     Structures.OrderedTypeEx
     ZMicromega.

From ITree Require Import
     ITree
     Basics.Basics
     Events.Exception
     Eq.Eq
     Events.StateFacts
     Events.State.

Import Basics.Basics.Monads.

From ExtLib Require Import
     Structures.Monads
     Programming.Eqv
     Data.String.

From Vellvm Require Import
     LLVMAst
     Util
     DynamicTypes
     Denotation
     MemoryAddress
     LLVMEvents
     Error
     Coqlib
     Numeric.Integers
     Numeric.Floats.

Require Import Ceres.Ceres.

Import MonadNotation.
Import EqvNotation.
Import ListNotations.

Set Implicit Arguments.
Set Contextual Implicit.
(* end hide *)

(** * Memory Model

    This file implements VIR's memory model as an handler for the [MemoryE] family of events.
    The model is inspired by CompCert's memory model, but differs in that it maintains two
    representation of the memory, a logical one and a low-level one.
    Pointers (type signature [MemoryAddress.ADDRESS]) are implemented as a pair containing
    an address and an offset.
*)

(** ** Type of pointers
    Implementation of the notion of pointer used: an address and an offset.
 *)
Module Addr : MemoryAddress.ADDRESS with Definition addr := (Z * Z) % type.
  Definition addr := (Z * Z) % type.
  Definition null := (0, 0).
  Definition t := addr.
  Lemma eq_dec : forall (a b : addr), {a = b} + {a <> b}.
  Proof.
    intros [a1 a2] [b1 b2].
    destruct (a1 ~=? b1);
      destruct (a2 ~=? b2); unfold eqv in *; unfold AstLib.eqv_int in *; subst.
    - left; reflexivity.
    - right. intros H. inversion H; subst. apply n. reflexivity.
    - right. intros H. inversion H; subst. apply n. reflexivity.
    - right. intros H. inversion H; subst. apply n. reflexivity.
  Qed.
End Addr.

(** ** Memory model
    Implementation of the memory model, i.e. a handler for [MemoryE].
    The memory itself, [memory], is a finite map (using the standard library's AVLs)
    indexed on [Z].
 *)
Module Make(LLVMEvents: LLVM_INTERACTIONS(Addr)).
  Import LLVMEvents.
  Import DV.
  Open Scope list.

  Definition addr := Addr.addr.

  Module IM := FMapAVL.Make(Coq.Structures.OrderedTypeEx.Z_as_OT).
  (* Polymorphic type of maps indexed by [Z] *)
  Definition IntMap := IM.t.

  Definition add {a} k (v:a) := IM.add k v.
  Definition delete {a} k (m:IntMap a) := IM.remove k m.
  Definition member {a} k (m:IntMap a) := IM.mem k m.
  Definition lookup {a} k (m:IntMap a) := IM.find k m.
  Definition empty {a} := @IM.empty a.

  (* Extends the map with a list of pairs key/value.
     Note: additions start from the end of the list, so in case of duplicate
     keys, the binding in the front will shadow though in the back.
   *)
  Fixpoint add_all {a} ks (m:IntMap a) :=
    match ks with
    | [] => m
    | (k,v) :: tl => add k v (add_all tl m)
    end.

  (* Extends the map with the bindings {(i,v_1) .. (i+n-1, v_n)} for [vs ::= v_1..v_n] *)
  Fixpoint add_all_index {a} vs (i:Z) (m:IntMap a) :=
    match vs with
    | [] => m
    | v :: tl => add i v (add_all_index tl (i+1) m)
    end.

  (* Give back a list of values from [|i|] to [|i| + |sz| - 1] in [m].
     Uses [def] as the default value if a lookup failed.
   *)
  Definition lookup_all_index {a} (i:Z) (sz:Z) (m:IntMap a) (def:a) : list a :=
    List.map (fun x =>
                let x' := lookup (Z.of_nat x) m in
                match x' with
                | None => def
                | Some val => val
                end) (seq (Z.to_nat i) (Z.to_nat sz)).

  (* Takes the join of two maps, favoring the first one over the intersection of their domains *)
  Definition union {a} (m1 : IntMap a) (m2 : IntMap a)
    := IM.map2 (fun mx my =>
                  match mx with | Some x => Some x | None => my end) m1 m2.

  (* TODO : Move the three following functions *)
    Fixpoint max_default (l:list Z) (x:Z) :=
    match l with
    | [] => x
    | h :: tl =>
      max_default tl (if h >? x then h else x)
    end.

  Definition maximumBy {A} (leq : A -> A -> bool) (def : A) (l : list A) : A :=
    fold_left (fun a b => if leq a b then b else a) l def.

  Definition is_some {A} (o : option A) :=
    match o with
    | Some x => true
    | None => false
    end.

  (* TODO SAZ: mem_block should keep track of its allocation size so
    that operations can fail if they are out of range

    CB: I think this might happen implicitly with make_empty_block --
    it initializes the IntMap with only the valid indices. As long as the
    lookup functions handle this properly, anyway.
   *)

  Section Datatype_Definition.

    (** ** Simple view of memory
      A concrete block is determined by its id and its size.
     *)
    Inductive concrete_block :=
    | CBlock (size : Z) (block_id : Z) : concrete_block.

    (** ** Logical view of memory
      A logical block is determined by a size and a mapping from [Z] to special bytes,
      we call such a mapping a [mem_block].
      Those bytes can either be an actually 8bits byte, an address of a pointer,
      a [PtrFrag], marking bytes that are part of an address but not its first byte,
      or a special undefined byte.
      It may also correspond to a concrete block whose id is then provided.
     *)
    Inductive SByte :=
    | Byte : byte -> SByte
    | Ptr : addr -> SByte
    | PtrFrag : SByte
    | SUndef : SByte.
    Definition mem_block       := IntMap SByte.
    Inductive logical_block :=
    | LBlock (size : Z) (bytes : mem_block) (concrete_id : option Z) : logical_block.

    (** ** Memory
      A concrete memory, resp. logical memory, maps addresses to concrete blocks, resp. logical blocks.
      A memory is a pair of both views of the memory.
     *)
    Definition concrete_memory := IntMap concrete_block.
    Definition logical_memory  := IntMap logical_block.
    Definition memory          := (concrete_memory * logical_memory)%type.

    (** ** Stack frames
      A frame contains the list of block ids that need to be freed when popped,
      i.e. when the function returns.
      A [frame_stack] is a list of such frames.
     *)
    Definition mem_frame := list Z.
    Definition frame_stack := list mem_frame.

    (** ** Memory stack
      The full notion of state manipulated by the monad is a pair of a [memory] and a [mem_stack].
     *)
    Definition memory_stack : Type := memory * frame_stack.

  End Datatype_Definition.

  Section Serialization.

   (** ** Serialization
       Conversion back and forth between values and their byte representation
   *)

    (* Converts an integer [x] to its byte representation over [n] bytes.
     The representation is little endian. In particular, if [n] is too small,
     only the least significant bytes are returned.
     *)
    Fixpoint bytes_of_int (n: nat) (x: Z) {struct n}: list byte :=
      match n with
      | O => nil
      | S m => Byte.repr x :: bytes_of_int m (x / 256)
      end.

    Definition sbytes_of_int (count:nat) (z:Z) : list SByte :=
      List.map Byte (bytes_of_int count z).

    (* Converts a list of bytes to an integer.
     The byte encoding is assumed to be little endian.
     *)
    Fixpoint int_of_bytes (l: list byte): Z :=
      match l with
      | nil => 0
      | b :: l' => Byte.unsigned b + int_of_bytes l' * 256
      end.

    (* Partial function casting a [Sbyte] into a simple [byte] *)
    (* CB TODO: Is interpreting everything except for bytes as undef reasonable? *)
    Definition Sbyte_to_byte (sb:SByte) : option byte :=
      match sb with
      | Byte b => ret b
      | Ptr _ | PtrFrag | SUndef => None
      end.

    Definition Sbyte_to_byte_list (sb:SByte) : list byte :=
      match sb with
      | Byte b => [b]
      | Ptr _ | PtrFrag | SUndef => []
      end.

    Definition sbyte_list_to_byte_list (bytes:list SByte) : list byte :=
      List.flat_map Sbyte_to_byte_list bytes.

    Definition sbyte_list_to_Z (bytes:list SByte) : Z :=
      int_of_bytes (sbyte_list_to_byte_list bytes).

    (** Length properties *)

    Lemma length_bytes_of_int:
      forall n x, List.length (bytes_of_int n x) = n.
    Proof.
      induction n; simpl; intros. auto. decEq. auto.
    Qed.

    Lemma int_of_bytes_of_int:
      forall n x,
        int_of_bytes (bytes_of_int n x) = x mod (two_p (Z.of_nat n * 8)).
    Proof.
      induction n; intros.
      simpl. rewrite Zmod_1_r. auto.
      Opaque Byte.wordsize.
      rewrite Nat2Z.inj_succ. simpl.
      replace (Z.succ (Z.of_nat n) * 8) with (Z.of_nat n * 8 + 8) by omega.
      rewrite two_p_is_exp; try omega.
      rewrite Zmod_recombine. rewrite IHn. rewrite Z.add_comm.
      change (Byte.unsigned (Byte.repr x)) with (Byte.Z_mod_modulus x).
      rewrite Byte.Z_mod_modulus_eq. reflexivity.
      apply two_p_gt_ZERO. omega. apply two_p_gt_ZERO. omega.
    Qed.

    (** ** Serialization of [dvalue]
      Serializes a dvalue into its SByte-sensitive form.
      Integer are stored over 8 bytes.
      Pointers as well: the address is stored in the first, [PtrFrag] flags mark the seven others.
     *)
    Fixpoint serialize_dvalue (dval:dvalue) : list SByte :=
      match dval with
      | DVALUE_Addr addr => (Ptr addr) :: (repeat PtrFrag 7)
      | DVALUE_I1 i => sbytes_of_int 8 (unsigned i)
      | DVALUE_I8 i => sbytes_of_int 8 (unsigned i)
      | DVALUE_I32 i => sbytes_of_int 8 (unsigned i)
      | DVALUE_I64 i => sbytes_of_int 8 (unsigned i)
      | DVALUE_Float f => sbytes_of_int 4 (unsigned (Float32.to_bits f))
      | DVALUE_Double d => sbytes_of_int 8 (unsigned (Float.to_bits d))
      | DVALUE_Struct fields
      | DVALUE_Array fields =>
        (* note the _right_ fold is necessary for byte ordering. *)
        fold_right (fun 'dv acc => ((serialize_dvalue dv) ++ acc) % list) [] fields
      | _ => [] (* TODO add more dvalues as necessary *)
      end.

    (** ** Well defined block
      A list of [sbytes] is considered undefined if any of its bytes is undefined.
      This predicate checks that they are all well-defined.
     *)
    Definition all_not_sundef (bytes : list SByte) : bool :=
      forallb is_some (map Sbyte_to_byte bytes).

    (** ** Size of a dynamic type
      Computes the byte size of a [dtyp]. *)
    Fixpoint sizeof_dtyp (ty:dtyp) : Z :=
      match ty with
      | DTYPE_I sz         => 8 (* All integers are padded to 8 bytes. *)
      | DTYPE_Pointer      => 8
      | DTYPE_Struct l     => fold_left (fun x acc => x + sizeof_dtyp acc) l 0
      | DTYPE_Array sz ty' => sz * sizeof_dtyp ty'
      | DTYPE_Float        => 4
      | DTYPE_Double       => 8
      | _                  => 0 (* TODO: add support for more types as necessary *)
      end.

    (** ** Deserialization of a list of sbytes
      Deserialize a list [bytes] of SBytes into a uvalue of type [t],
      assuming that none of the bytes are undef.
      Truncate integer as dictated by [t].
     *)
    Fixpoint deserialize_sbytes_defined (bytes:list SByte) (t:dtyp) : uvalue :=
      match t with
      | DTYPE_I sz =>
        let des_int := sbyte_list_to_Z bytes in
        match sz with
        | 1  => UVALUE_I1 (repr des_int)
        | 8  => UVALUE_I8 (repr des_int)
        | 32 => UVALUE_I32 (repr des_int)
        | 64 => UVALUE_I64 (repr des_int)
        | _  => UVALUE_None (* invalid size. *)
        end
      | DTYPE_Float => UVALUE_Float (Float32.of_bits (repr (sbyte_list_to_Z bytes)))
      | DTYPE_Double => UVALUE_Double (Float.of_bits (repr (sbyte_list_to_Z bytes)))

      | DTYPE_Pointer =>
        match bytes with
        | Ptr addr :: tl => UVALUE_Addr addr
        | _ => UVALUE_None (* invalid pointer. *)
        end
      | DTYPE_Array sz t' =>
        let fix array_parse count byte_sz bytes :=
            match count with
            | O => []
            | S n => (deserialize_sbytes_defined (firstn byte_sz bytes) t')
                      :: array_parse n byte_sz (skipn byte_sz bytes)
            end in
        UVALUE_Array (array_parse (Z.to_nat sz) (Z.to_nat (sizeof_dtyp t')) bytes)
      | DTYPE_Struct fields =>
        let fix struct_parse typ_list bytes :=
            match typ_list with
            | [] => []
            | t :: tl =>
              let size_ty := Z.to_nat (sizeof_dtyp t) in
              (deserialize_sbytes_defined (firstn size_ty bytes) t)
                :: struct_parse tl (skipn size_ty bytes)
            end in
        UVALUE_Struct (struct_parse fields bytes)
      | _ => UVALUE_None (* TODO add more as serialization support increases *)
      end.

    (* Returns undef if _any_ sbyte is undef.
     Note that this means for instance that the result of the deserialization of an I1
     depends on all the bytes provided, not just the first one!
     *)
    Definition deserialize_sbytes (bytes : list SByte) (t : dtyp) : uvalue :=
      if all_not_sundef bytes
      then deserialize_sbytes_defined bytes t
      else UVALUE_Undef t.

    (** ** Reading values in memory
      Given an offset in [mem_block], we decode a [uvalue] at [dtyp] [t] by looking up the
      appropriate number of [SByte] and deserializing them.
     *)
    Definition read_in_mem_block (bk : mem_block) (offset : Z) (t : dtyp) : uvalue :=
      deserialize_sbytes (lookup_all_index offset (sizeof_dtyp t) bk SUndef) t.

    (* Todo - complete proofs, and think about moving to MemoryProp module. *)
    (* The relation defining serializable dvalues. *)
    Inductive serialize_defined : dvalue -> Prop :=
    | d_addr: forall addr,
        serialize_defined (DVALUE_Addr addr)
    | d_i1: forall i1,
        serialize_defined (DVALUE_I1 i1)
    | d_i8: forall i1,
        serialize_defined (DVALUE_I8 i1)
    | d_i32: forall i32,
        serialize_defined (DVALUE_I32 i32)
    | d_i64: forall i64,
        serialize_defined (DVALUE_I64 i64)
    | d_struct_empty:
        serialize_defined (DVALUE_Struct [])
    | d_struct_nonempty: forall dval fields_list,
        serialize_defined dval ->
        serialize_defined (DVALUE_Struct fields_list) ->
        serialize_defined (DVALUE_Struct (dval :: fields_list))
    | d_array_empty:
        serialize_defined (DVALUE_Array [])
    | d_array_nonempty: forall dval fields_list,
        serialize_defined dval ->
        serialize_defined (DVALUE_Array fields_list) ->
        serialize_defined (DVALUE_Array (dval :: fields_list)).

    (* Lemma assumes all integers encoded with 8 bytes. *)

    Inductive sbyte_list_wf : list SByte -> Prop :=
    | wf_nil : sbyte_list_wf []
    | wf_cons : forall b l, sbyte_list_wf l -> sbyte_list_wf (Byte b :: l)
    .

  (*
Lemma sbyte_list_to_Z_inverse:
  forall i1 : int1, (sbyte_list_to_Z (Z_to_sbyte_list 8 (Int1.unsigned i1))) =
               (Int1.unsigned i1).
Proof.
  intros i1.
  destruct i1. simpl.
Admitted. *)

  (*
Lemma serialize_inverses : forall dval,
    serialize_defined dval -> exists typ, deserialize_sbytes (serialize_dvalue dval) typ = dval.
Proof.
  intros. destruct H.
  (* DVALUE_Addr. Type of pointer is not important. *)
  - exists (TYPE_Pointer TYPE_Void). reflexivity.
  (* DVALUE_I1. Todo: subversion lemma for integers. *)
  - exists (TYPE_I 1).
    simpl.


    admit.
  (* DVALUE_I32. Todo: subversion lemma for integers. *)
  - exists (TYPE_I 32). admit.
  (* DVALUE_I64. Todo: subversion lemma for integers. *)
  - exists (TYPE_I 64). admit.
  (* DVALUE_Struct [] *)
  - exists (TYPE_Struct []). reflexivity.
  (* DVALUE_Struct fields *)
  - admit.
  (* DVALUE_Array [] *)
  - exists (TYPE_Array 0 TYPE_Void). reflexivity.
  (* DVALUE_Array fields *)
  - admit.
Admitted.
   *)

  End Serialization.

  Section GEP.

    (** ** Get Element Pointer
      Retrieve the address of a subelement of an indexable (i.e. aggregate) [dtyp] [t] (i.e. vector, array, struct, packed struct).
      The [off]set parameter contains the current entry address of the aggregate structure being analyzed, while the list
      of [dvalue] [vs] describes the indexes of interest used to access the subelement.
      The interpretation of these values slightly depends on the type considered.
      But essentially, for instance in a vector or an array, the head value should be an [i32] describing the index of interest.
      The offset is therefore incremented by this index times the size of the type of elements stored. Finally, a recursive call
      at this new offset allows for deeper unbundling of a nested structure.
     *)
    Fixpoint handle_gep_h (t:dtyp) (off:Z) (vs:list dvalue): err Z :=
      match vs with
      | v :: vs' =>
        match v with
        | DVALUE_I32 i =>
          let k := unsigned i in
          let n := BinIntDef.Z.to_nat k in
          match t with
          | DTYPE_Vector _ ta
          | DTYPE_Array _ ta =>
            handle_gep_h ta (off + k * (sizeof_dtyp ta)) vs'
          | DTYPE_Struct ts
          | DTYPE_Packed_struct ts => (* Handle these differently in future *)
            let offset := fold_left (fun acc t => acc + sizeof_dtyp t)
                                    (firstn n ts) 0 in
            match nth_error ts n with
            | None => failwith "overflow"
            | Some t' =>
              handle_gep_h t' (off + offset) vs'
            end
          | _ => failwith ("non-i32-indexable type")
          end
        | DVALUE_I8 i =>
          let k := unsigned i in
          let n := BinIntDef.Z.to_nat k in
          match t with
          | DTYPE_Vector _ ta
          | DTYPE_Array _ ta =>
            handle_gep_h ta (off + k * (sizeof_dtyp ta)) vs'
          | _ => failwith ("non-i8-indexable type")
          end
        | DVALUE_I64 i =>
          let k := unsigned i in
          let n := BinIntDef.Z.to_nat k in
          match t with
          | DTYPE_Vector _ ta
          | DTYPE_Array _ ta =>
            handle_gep_h ta (off + k * (sizeof_dtyp ta)) vs'
          | _ => failwith ("non-i64-indexable type")
          end
        | _ => failwith "non-I32 index"
        end
      | [] => ret off
      end.

    (* At the toplevel, GEP takes a [dvalue] as an argument that must contain a pointer, but no other pointer can be recursively followed.
     The pointer set the block into which we look, and the initial offset. The first index value add to the initial offset passed to
     [handle_gep_h] for the actual access to structured data.
     *)
    Definition handle_gep (t:dtyp) (dv:dvalue) (vs:list dvalue) : err dvalue :=
      match vs with
      | DVALUE_I32 i :: vs' => (* TODO: Handle non i32 / i64 indices *)
        match dv with
        | DVALUE_Addr (b, o) =>
          off <- handle_gep_h t (o + (sizeof_dtyp t) * (unsigned i)) vs' ;;
          ret (DVALUE_Addr (b, off))
        | _ => failwith "non-address"
        end
      | DVALUE_I64 i :: vs' =>
        match dv with
        | DVALUE_Addr (b, o) =>
          off <- handle_gep_h t (o + (sizeof_dtyp t) * (unsigned i)) vs' ;;
          ret (DVALUE_Addr (b, off))
        | _ => failwith "non-address"
        end
      | _ => failwith "non-I32 index"
      end.

  End GEP.

  Section Logical_Operations.

    Definition logical_empty : logical_memory := empty.

    (* Returns a fresh key for use in memory map *)
    Definition logical_next_key (m : logical_memory) : Z
      := let keys := map fst (IM.elements m) in
         1 + maximumBy Z.leb (-1) keys.

    (** ** Initialization of blocks
      Constructs an initial [mem_block] of undefined [SByte]s, indexed from 0 to n.
     *)
    Fixpoint init_block_undef (n:nat) (m:mem_block) : mem_block :=
      match n with
      | O => add 0 SUndef m
      | S n' => add (Z.of_nat n) SUndef (init_block_undef n' m)
      end.

    (* Constructs an initial [mem_block] containing [n] undefined [SByte]s, indexed from [0] to [n - 1].
     If [n] is negative, it is treated as [0].
     *)
    Definition init_block (n:Z) : mem_block :=
      match n with
      | 0 => empty
      | Z.pos n' => init_block_undef (BinPosDef.Pos.to_nat (n' - 1)) empty
      | Z.neg _ => empty (* invalid argument *)
      end.

    (* Constructs an initial [mem_block] appropriately sized for a given type [ty]. *)
    Definition make_empty_mem_block (ty:dtyp) : mem_block :=
      init_block (sizeof_dtyp ty).

    (* Constructs an initial [logical_block] appropriately sized for a given type [ty]. *)
    Definition make_empty_logical_block (ty:dtyp) : logical_block :=
      let block := make_empty_mem_block ty in
      LBlock (sizeof_dtyp ty) block None.

    (** ** Single element lookup
     *)
    Definition get_value_mem_block (bk : mem_block) (bk_offset : Z) (t : dtyp) : uvalue :=
      read_in_mem_block bk bk_offset t.

    (** ** Array element lookup
      A [mem_block] can be seen as storing an array of elements of [dtyp] [t], from which we retrieve
      the [i]th [uvalue].
      The [size] argument has no effect, but we need to provide one to the array type.
     *)
    Definition get_array_mem_block_at_i (bk : mem_block) (bk_offset : Z) (i : nat) (size : Z) (t : dtyp) : err uvalue :=
      'offset <- handle_gep_h (DTYPE_Array size t)
                             bk_offset
                             [DVALUE_I64 (DynamicValues.Int64.repr (Z.of_nat i))];;
      inr (read_in_mem_block bk offset t).

    (** ** Array lookups -- mem_block
      Retrieve the values stored at position [from] to position [to - 1] in an array stored in a [mem_block].
     *)
    Definition get_array_mem_block (bk : mem_block) (bk_offset : Z) (from to : nat) (size : Z) (t : dtyp) : err (list uvalue) :=
      map_monad (fun i => get_array_mem_block_at_i bk bk_offset i size t) (seq from (to - 1)).

  End Logical_Operations.

  Section Concrete_Operations.

    Definition concrete_empty : concrete_memory := empty.

    Definition concrete_next_key (m : concrete_memory) : Z :=
      let keys         := List.map fst (IM.elements m) in
      let max          := max_default keys 0 in
      let offset       := 1 in (* TODO: This should be "random" *)
      match lookup max m with
      | None => offset
      | Some (CBlock sz _) => max + sz + offset
      end.

  End Concrete_Operations.

  Section Memory_Operations.

      (** ** Smart lookups *)
      Definition get_concrete_block_mem (b : Z) (m : memory) : option concrete_block :=
        let concrete_map := fst m in
        lookup b concrete_map.

      Definition get_logical_block_mem (b : Z) (m : memory) : option logical_block :=
        let logical_map := snd m in
        lookup b logical_map.

      (* Get the next key in the logical map *)
      Definition next_logical_key_mem (m : memory) : Z :=
        logical_next_key (snd m).

      (* Get the next key in the concrete map *)
      Definition next_concrete_key_mem (m : memory) : Z :=
        concrete_next_key (fst m).

      (** ** Extending the memory  *)
      Definition add_concrete_block_mem (id : Z) (b : concrete_block) (m : memory) : memory :=
        match m with
        | (cm, lm) =>
          (add id b cm, lm)
        end.

      Definition add_logical_block_mem (id : Z) (b : logical_block) (m : memory) : memory :=
        match m with
        | (cm, lm) =>
          (cm, add id b lm)
        end.

      (** ** Concretization of blocks
          Look-ups a concrete block in memory. The logical memory acts first as a potential layer of indirection:
          - if no logical block is found, the input is directly returned.
          - if a logical block is found, and that a concrete block is associated, the address of this concrete block
          is returned, paired with the input memory.
          - if a logical block is found, but that no concrete block is (yet) associated to it, then the associated
          concrete block is allocated, and the association is added to the logical block.
       *)
      Definition concretize_block_mem (b:Z) (m:memory) : Z * memory :=
        match get_logical_block_mem b m with
        | None => (b, m) (* TODO: Not sure this makes sense??? *)
        | Some (LBlock sz bytes (Some cid)) => (cid, m)
        | Some (LBlock sz bytes None) =>
          (* Allocates a concrete block for this one *)
          let id        := next_concrete_key_mem m in
          let new_block := CBlock sz b in
          let m'        := add_concrete_block_mem id new_block m in
          let m''       := add_logical_block_mem  b (LBlock sz bytes (Some id)) m' in
          (id, m'')
        end.

      (** ** Abstraction of blocks
          Retrieve a logical description of a block as address and offset from its concrete address.
          The non-trivial part consists in extracting from the [concrete_memory] the concrete address
          and block corresponding to a logical one.
       *)
      Definition get_real_cid (cid : Z) (m : memory) : option (Z * concrete_block)
        := IM.fold (fun k '(CBlock sz bid) a => if (k <=? cid) && (cid <? k + sz)
                                             then Some (k, CBlock sz bid)
                                             else a) (fst m) None.

      Definition concrete_address_to_logical_mem (cid : Z) (m : memory) : option (Z * Z)
        := match m with
           | (cm, lm) =>
             '(rid, CBlock sz bid) <- get_real_cid cid m ;;
             ret (bid, cid-rid)
           end.

      (* LLVM 5.0 memcpy
         According to the documentation: http://releases.llvm.org/5.0.0/docs/LangRef.html#llvm-memcpy-intrinsic
         this operation can never fail?  It doesn't return any status code...
       *)

      (* TODO probably doesn't handle sizes correctly... *)
      (** ** MemCopy
          Implementation of the [memcpy] intrinsics.
       *)
      Definition handle_memcpy (args : list dvalue) (m:memory) : err memory :=
        match args with
        | DVALUE_Addr (dst_b, dst_o) ::
                      DVALUE_Addr (src_b, src_o) ::
                      DVALUE_I32 len ::
                      DVALUE_I32 align :: (* alignment ignored *)
                      DVALUE_I1 volatile :: [] (* volatile ignored *)  =>

          src_block <- trywith "memcpy src block not found" (get_logical_block_mem src_b m) ;;
          dst_block <- trywith "memcpy dst block not found" (get_logical_block_mem dst_b m) ;;

          let src_bytes
              := match src_block with
                 | LBlock size bytes concrete_id => bytes
                 end in
          let '(dst_sz, dst_bytes, dst_cid)
              := match dst_block with
                 | LBlock size bytes concrete_id => (size, bytes, concrete_id)
                 end in
          let sdata := lookup_all_index src_o (unsigned len) src_bytes SUndef in
          let dst_bytes' := add_all_index sdata dst_o dst_bytes in
          let dst_block' := LBlock dst_sz dst_bytes' dst_cid in
          let m' := add_logical_block_mem dst_b dst_block' m in
          (ret m' : err memory)
        | _ => failwith "memcpy got incorrect arguments"
        end.

  End Memory_Operations.

  Section Frame_Stack_Operations.

    (* The initial frame stack is not an empty stack, but a singleton stack containing an empty frame *)
    Definition frame_empty : frame_stack := [[]].

    (** ** Free
        [free_frame f m] deallocates the frame [f] from the memory [m].
        This acts on both representations of the memory:
        - on the logical memory, it simply removes all keys indicated by the frame;
        - on the concrete side, for each element of the frame, we lookup in the logical memory
        if it is bounded to a logical block, and if so if this logical block contains an associated
        concrete block. If so, we delete this association from the concrete memory.
     *)
    Definition free_concrete_of_logical
               (b : Z)
               (lm : logical_memory)
               (cm : concrete_memory) : concrete_memory
      := match lookup b lm with
         | None => cm
         | Some (LBlock _ _ None) => cm
         | Some (LBlock _ _ (Some cid)) => delete cid cm
         end.

    Definition free_frame_memory (f : mem_frame) (m : memory) : memory :=
      let '(cm, lm) := m in
      let cm' := fold_left (fun m key => free_concrete_of_logical key lm m) f cm in
      (cm', fold_left (fun m key => delete key m) f lm).

  End Frame_Stack_Operations.

  Section Memory_Stack_Operations.

   (** ** Top-level interface
       Ideally, outside of this module, the [memory_stack] datatype should be abstract and all interactions should go
       through this interface.
    *)

    (** ** The empty memory
        Both the concrete and logical views of the memory are empty maps, i.e. nothing is allocated.
        It is a matter of convention, by we consider the empty memory to contain a single empty frame
        in its stack, rather than an empty stack.
     *)
    Definition empty_memory_stack : memory_stack := ((concrete_empty, logical_empty), frame_empty).

    (** ** Smart lookups *)

    Definition get_concrete_block (m : memory_stack) (ptr : addr) : option concrete_block :=
      let '(b,a) := ptr in
      get_concrete_block_mem b (fst m).

    Definition get_logical_block (m : memory_stack) (ptr : addr) : option logical_block :=
      let '(b,a) := ptr in
      get_logical_block_mem b (fst m).

    (** ** Fresh key getters *)

    (* Get the next key in the logical map *)
    Definition next_logical_key (m : memory_stack) : Z :=
      next_logical_key_mem (fst m).
    
    (* Get the next key in the concrete map *)
    Definition next_concrete_key (m : memory_stack) : Z :=
      next_concrete_key_mem (fst m).

    (** ** Extending the memory  *)
    Definition add_concrete_block (id : Z) (b : concrete_block) (m : memory_stack) : memory_stack :=
      let '(m,s) := m in (add_concrete_block_mem id b m,s).

    Definition add_logical_block (id : Z) (b : logical_block) (m : memory_stack) : memory_stack :=
      let '(m,s) := m in (add_logical_block_mem id b m,s).

    (** ** Single element lookup -- memory_stack
        Retreive the value stored at address [a] in memory [m].
     *)
    Definition get_value (m : memory_stack) (a : addr) (t : dtyp) : err uvalue :=
      let '(b, o) := a in
      match get_logical_block m a with
      | Some (LBlock _ bk _) => ret (get_value_mem_block bk o t)
      | None => failwith "Memory function [get_value] called at a non-allocated address"
      end.

    (** ** Array lookups -- memory_stack
      Retrieve the values stored at position [from] to position [to - 1] in an array stored at address [a] in memory.
     *)
    Definition get_array (m: memory_stack) (a : addr) (from to: nat) (size : Z) (t : dtyp) : err (list uvalue) :=
      let '(b, o) := a in
      match get_logical_block m a with
      | Some (LBlock _ bk _) =>
        get_array_mem_block bk o from to size t
      | None => failwith "Memory function [get_array] called at a non-allocated address"
      end.

    Definition free_frame (m : memory_stack) : err memory_stack :=
      let '(m,sf) := m in
      match sf with
      | [] => failwith "Attempting to free a frame from a currently empty stack of frame"
      | f :: sf => inr (free_frame_memory f m,sf)
      end.

    Definition push_fresh_frame (m : memory_stack) : memory_stack :=
      let '(m,s) := m in (m, [] :: s).

    Definition add_to_frame (m : memory_stack) (k : Z) : err memory_stack :=
      let '(m,s) := m in
      match s with
      | [] => failwith "Attempting to allocate in a currently empty stack of frame"
      | f :: s => ret (m, (k :: f) :: s)
      end.
      
    Definition allocate (m : memory_stack) (t : dtyp) : err (memory_stack * Z) :=
      let new_block := make_empty_logical_block t in
      let key       := next_logical_key m in
      let m         := add_logical_block key new_block m in
      'm <- add_to_frame m key;;
      ret (m,key).

    Definition read (m : memory_stack) (ptr : addr) (t : dtyp) : err uvalue :=
      match get_logical_block m ptr with
      | Some (LBlock _ block _) =>
        ret (read_in_mem_block block (snd ptr) t)
      | None => failwith "Attempting to read a non-allocated address"
      end.

    Definition write (m : memory_stack) (ptr : addr) (v : dvalue) : err memory_stack :=
      match get_logical_block m ptr with
      | Some (LBlock sz bytes cid) =>
        let '(b,off) := ptr in
        let bytes' := add_all_index (serialize_dvalue v) off bytes in
        let block' := LBlock sz bytes' cid in
        ret (add_logical_block b block' m) 
      | None => failwith "Attempting to write to a non-allocated address"
      end.

    Definition concrete_address_to_logical (cid : Z) (m : memory_stack) : option (Z * Z) :=
      concrete_address_to_logical_mem cid (fst m).

    Definition concretize_block (ptr : addr) (m : memory_stack) : Z * memory_stack :=
      let '(b', m') := concretize_block_mem (fst ptr) (fst m) in
      (b', (m', snd m)).

  End Memory_Stack_Operations.

  (** ** Memory Handler
      Implementation of the memory model per se as a memory handler to the [MemoryE] interface.
   *)
  Definition handle_memory {E} `{FailureE -< E} `{UBE -< E}: MemoryE ~> stateT memory_stack (itree E) :=
    fun _ e m =>
      match e with
      | MemPush =>
        ret (push_fresh_frame m, tt)

      | MemPop =>
        'm' <- lift_pure_err (free_frame m);;
        ret (m',tt)

      | Alloca t =>
        '(m',key) <- lift_pure_err (allocate m t);;
        ret (m', DVALUE_Addr (key,0))

      | Load t dv =>
        match dv with
        | DVALUE_Addr ptr =>
          match read m ptr t with
          | inr v => ret (m, v)
          | inl s => raiseUB s
          end
        | _ => raise "Attempting to load from a non-address dvalue"
        end

      | Store dv v =>
        match dv with
        | DVALUE_Addr ptr =>
          'm' <- lift_pure_err (write m ptr v);;
          ret (m', tt)
        | _ => raise ("Attemptingeto store to a non-address dvalue: " ++ (to_string dv))
        end

      | GEP t dv vs =>
        'dv' <- lift_pure_err (handle_gep t dv vs);;
        ret (m, dv')

      | ItoP x =>
        match x with
        | DVALUE_I64 i =>
          match concrete_address_to_logical (unsigned i) m with
          | None => raise ("Invalid concrete address " ++ (to_string x))
          | Some (b, o) => ret (m, DVALUE_Addr (b, o))
          end
        | DVALUE_I32 i =>
          match concrete_address_to_logical (unsigned i) m with
          | None => raise "Invalid concrete address "
          | Some (b, o) => ret (m, DVALUE_Addr (b, o))
          end
        | DVALUE_I8 i  =>
          match concrete_address_to_logical (unsigned i) m with
          | None => raise "Invalid concrete address"
          | Some (b, o) => ret (m, DVALUE_Addr (b, o))
          end
        | DVALUE_I1 i  =>
          match concrete_address_to_logical (unsigned i) m with
          | None => raise "Invalid concrete address"
          | Some (b, o) => ret (m, DVALUE_Addr (b, o))
          end
        | _            => raise "Non integer passed to ItoP"
        end
          
      (* TODO take integer size into account *)
      | PtoI t a =>
        match a, t with
        | DVALUE_Addr ptr, DTYPE_I sz =>
          let (cid, m') := concretize_block ptr m in
          'addr <- lift_undef_or_err ret (coerce_integer_to_int sz (cid + (snd ptr))) ;;
          ret (m', addr)
        | _, _ => raise "PtoI type error."
        end

      end.

  Definition handle_intrinsic {E} `{FailureE -< E} `{PickE -< E}: IntrinsicE ~> stateT memory_stack (itree E) :=
    fun _ e '(m, s) =>
      match e with
      | Intrinsic t name args =>
        (* Pick all arguments, they should all be unique. *)
        if string_dec name "llvm.memcpy.p0i8.p0i8.i32" then  (* FIXME: use reldec typeclass? *)
          match handle_memcpy args m with
          | inl err => raise err
          | inr m' => ret ((m', s), DVALUE_None)
          end
        else
          raise ("Unknown intrinsic: " ++ name)
      end.


  (* TODO: clean this up *)
  (* {E} `{failureE -< E} : IO ~> stateT memory (itree E)  *)
  (* Won't need to be case analysis, just passes through failure + debug *)
  (* Might get rid of this one *)
  (* This can't show that IO ∉ E :( *)
  (* Alternative 2: Fix order of effects

   Layer interpretors so that they each chain into the next. Have to
   do ugly matches everywhere :(.

   Split the difference:

   `{IO -< IO +' failureE +' debugE}

   Alternative 3: follow 2, and then use notations to make things better.

   Alternative 4: Extend itrees mechanisms with some kind of set operations.

   If you want to allow sums on the left of your handlers, you want
   this notion of an atomic handler / event, which is different from a
   variable or a sum...

   `{E +' F -< G}

   This seems too experimental to try to work out now --- chat with Li-yao about it.

   Alternative 2 might be the most straightforward way to get things working in the short term.

   We just want to get everything hooked together to build and test
   it. Then think about making the interfaces nicer. The steps to alt
   2, start with LLVM1 ordering as the basic default. Then each stage
   of interpretation peels off one, or reintroduces the same kind of
   events / changes it.


   *)
  Section PARAMS.
    Variable (E F G : Type -> Type).
    Context `{FailureE -< F} `{UBE -< F} `{PickE -< F}.
    Notation Effin := (E +' IntrinsicE +' MemoryE +' F).
    Notation Effout := (E +' F).

    Definition E_trigger {M} : forall R, E R -> (stateT M (itree Effout) R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition F_trigger {M} : forall R, F R -> (stateT M (itree Effout) R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition interp_memory_h := case_ E_trigger (case_ handle_intrinsic  (case_ handle_memory  F_trigger)).
    Definition interp_memory :
      itree Effin ~> stateT memory_stack (itree Effout) :=
      interp_state interp_memory_h.

    Section Structural_Lemmas.

      Lemma interp_memory_bind :
        forall (R S : Type) (t : itree Effin R) (k : R -> itree Effin S) m,
          interp_memory (ITree.bind t k) m ≅
                        ITree.bind (interp_memory t m) (fun '(m',r) => interp_memory (k r) m').
      Proof.
        intros.
        unfold interp_memory.
        setoid_rewrite interp_state_bind.
        apply eq_itree_clo_bind with (UU := Logic.eq).
        reflexivity.
        intros [] [] EQ; inv EQ; reflexivity.
      Qed.

      Lemma interp_memory_ret :
        forall (R : Type) g (x: R),
          interp_memory (Ret x: itree Effin R) g ≅ Ret (g,x).
      Proof.
        intros; apply interp_state_ret.
      Qed.

      Lemma interp_memory_vis_eqit:
        forall S X (kk : X -> itree Effin S) m
          (e : Effin X),
          interp_memory (Vis e kk) m ≅ ITree.bind (interp_memory_h e m) (fun sx => Tau (interp_memory (kk (snd sx)) (fst sx))).
      Proof.
        intros.
        unfold interp_memory.
        setoid_rewrite interp_state_vis.
        reflexivity.
      Qed.

      Lemma interp_memory_vis:
        forall m S X (kk : X -> itree Effin S) (e : Effin X),
          interp_memory (Vis e kk) m ≈ ITree.bind (interp_memory_h e m) (fun sx => interp_memory (kk (snd sx)) (fst sx)).
      Proof.
        intros.
        rewrite interp_memory_vis_eqit.
        apply eutt_eq_bind.
        intros ?; tau_steps; reflexivity.
      Qed.

      Lemma interp_memory_trigger:
        forall (m : memory_stack) X (e : Effin X),
          interp_memory (ITree.trigger e) m ≈ interp_memory_h e m.
      Proof.
        intros.
        unfold interp_memory.
        rewrite interp_state_trigger.
        reflexivity.
      Qed.

      Lemma interp_memory_bind_trigger_eqit:
        forall m S X (kk : X -> itree Effin S) (e : Effin X),
          interp_memory (ITree.bind (trigger e) kk) m ≅ ITree.bind (interp_memory_h e m) (fun sx => Tau (interp_memory (kk (snd sx)) (fst sx))).
      Proof.
        intros.
        unfold interp_memory.
        rewrite bind_trigger.
        setoid_rewrite interp_state_vis.
        reflexivity.
      Qed.

      Lemma interp_memory_bind_trigger:
        forall m S X
          (kk : X -> itree Effin S)
          (e : Effin X),
          interp_memory (ITree.bind (trigger e) kk) m ≈ ITree.bind (interp_memory_h e m) (fun sx => interp_memory (kk (snd sx)) (fst sx)).
      Proof.
        intros.
        rewrite interp_memory_bind_trigger_eqit.
        apply eutt_eq_bind.
        intros ?; tau_steps; reflexivity.
      Qed.

      Global Instance eutt_interp_memory {R} :
        Proper (eutt Logic.eq ==> Logic.eq ==> eutt Logic.eq) (@interp_memory R).
      Proof.
        repeat intro.
        unfold interp_memory.
        subst; rewrite H2.
        reflexivity.
      Qed.

    End Structural_Lemmas.

  End PARAMS.

End Make.
