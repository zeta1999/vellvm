From Coq Require Import
     String.

From ExtLib Require Import
     Structures.Monads
     Structures.Maps.

From ITree Require Import
     ITree
     Eq
     Events.State
     Events.StateFacts.

From Vellvm Require Import
     Util
     LLVMAst
     AstLib
     MemoryAddress
     DynamicValues
     LLVMEvents
     Error.

Require Import Ceres.Ceres.

Set Implicit Arguments.
Set Contextual Implicit.

Import MonadNotation.
Import ITree.Basics.Basics.Monads.
Open Scope string_scope.

Section Locals.
  Variable (k v:Type).
  Context {map : Type}.
  Context {M: Map k v map}.
  Context {SK : Serialize k}.
  Definition handle_local {E} `{FailureE -< E} : (LocalE k v) ~> stateT map (itree E) :=
    fun _ e env =>
      match e with
      | LocalWrite k v => ret (Maps.add k v env, tt)
      | LocalRead k =>
        match Maps.lookup k env with
        | Some v => Ret (env, v)
        | None => raise ("Could not look up id " ++ to_string k)
        end
      end.

  Open Scope monad_scope.
  Section PARAMS.
    Variable (E F G H: Type -> Type).
    Context `{FailureE -< G}.
    Notation Effin := (E +' F +' (LocalE k v) +' G).
    Notation Effout := (E +' F +' G).

    Definition E_trigger {M} : forall R, E R -> (stateT M (itree Effout) R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition F_trigger {M} : forall R, F R -> (stateT M (itree Effout) R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition G_trigger {M} : forall R , G R -> (stateT M (itree Effout) R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition interp_local_h := (case_ E_trigger (case_ F_trigger (case_ handle_local G_trigger))).
    Definition interp_local : itree Effin ~> stateT map (itree Effout) :=
      interp_state interp_local_h.


    Section Structural_Lemmas.

      Lemma interp_local_bind :
        forall (R S : Type) (t : itree Effin R) (k : R -> itree Effin S) s,
          interp_local (ITree.bind t k) s ≅
                       ITree.bind (interp_local t s) (fun '(s',r) => interp_local (k r) s').
      Proof.
        intros.
        unfold interp_local.
        setoid_rewrite interp_state_bind.
        apply eq_itree_clo_bind with (UU := Logic.eq).
        reflexivity.
        intros [] [] EQ; inv EQ; reflexivity.
      Qed.

      Lemma interp_local_ret :
        forall (R : Type) g (x: R),
          interp_local (Ret x: itree Effin R) g ≅ Ret (g,x).
      Proof.
        intros; apply interp_state_ret.
      Qed.

      Lemma interp_local_vis_eqit:
        forall (g : map) S X
          (kk : X -> itree Effin S)
          (e : Effin X),
          interp_local (Vis e kk) g ≅ ITree.bind (interp_local_h e g) (fun (sx : map * X) => Tau (interp_local (kk (snd sx)) (fst sx))).
      Proof.
        intros.
        unfold interp_local.
        setoid_rewrite interp_state_vis.
        reflexivity.
      Qed.

      Lemma interp_local_vis:
        forall (g : map) S X (kk : X -> itree Effin S) (e : Effin X),
          interp_local (Vis e kk) g ≈ ITree.bind (interp_local_h e g) (fun (sx : map * X) => interp_local (kk (snd sx)) (fst sx)).
      Proof.
        intros.
        rewrite interp_local_vis_eqit.
        apply eutt_eq_bind.
        intros ?; tau_steps; reflexivity.
      Qed.

      Lemma interp_local_trigger:
        forall (g : map) X (e : Effin X),
          interp_local (ITree.trigger e) g ≈ interp_local_h e g.
      Proof.
        intros.
        unfold interp_local.
        rewrite interp_state_trigger.
        reflexivity.
      Qed.

      Lemma interp_local_bind_trigger_eqit:
        forall (g : map) S X (kk : X -> itree Effin S) (e : Effin X),
          interp_local (ITree.bind (trigger e) kk) g ≅ ITree.bind (interp_local_h e g) (fun (sx : map * X) => Tau (interp_local (kk (snd sx)) (fst sx))).
      Proof.
        intros.
        unfold interp_local.
        rewrite bind_trigger.
        setoid_rewrite interp_state_vis.
        reflexivity.
      Qed.

      Lemma interp_local_trigger_bind:
        forall (g : map) S X (kk : X -> itree Effin S) (e : Effin X),
          interp_local (ITree.bind (trigger e) kk) g ≈ ITree.bind (interp_local_h e g) (fun (sx : map * X) => interp_local (kk (snd sx)) (fst sx)).
      Proof.
        intros.
        rewrite interp_local_bind_trigger_eqit.
        apply eutt_eq_bind.
        intros ?; tau_steps; reflexivity.
      Qed.

    End Structural_Lemmas.

  (** ** DEPRECATED
        TODO : Double check, garbage collect
   *)
  (*
    Notation Effin' := (E +' F +' H +' (LocalE k v) +' G).
    Notation Effout' := (E +' F +' H +' G).

    Definition E_trigger' {M} : forall R, E R -> (stateT M (itree Effout') R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition F_trigger' {M} : forall R, F R -> (stateT M (itree Effout') R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition H_trigger' {M} : forall R, H R -> (stateT M (itree Effout') R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition G_trigger' {M} : forall R , G R -> (stateT M (itree Effout') R) :=
      fun R e m => r <- trigger e ;; ret (m, r).

    Definition interp_local' : itree Effin' ~> stateT map (itree Effout') :=
      interp_state (case_ E_trigger' (case_ F_trigger' (case_ H_trigger' (case_ handle_local G_trigger')))).


   *) 
  End PARAMS.

End Locals.
