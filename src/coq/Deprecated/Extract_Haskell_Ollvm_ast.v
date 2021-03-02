(* -------------------------------------------------------------------------- *
 *                     Vir - the Verified LLVM project                     *
 *                                                                            *
 *     Anonymized              *
 *     Copyright (c) 2017 Joachim Breitner <joachim@cis.upenn.edu>            *
 *                                                                            *
 *   This file is distributed under the terms of the GNU General Public       *
 *   License as published by the Free Software Foundation, either version     *
 *   3 of the License, or (at your option) any later version.                 *
 ---------------------------------------------------------------------------- *)

Require Import Ascii String.
Extraction Language Haskell.

Require Import Vir.LLVMAst.

Extract Inductive option => "Prelude.Maybe" [ "Nothing" "Just" ].
Extract Inductive list => "[]" [ "[]" "(:)" ].
Extract Inductive prod => "(,)" [ "(,)" ].
Extract Inductive string => "Prelude.String" [ "[]" "(:)" ].
Extract Inductive bool => "Prelude.Bool" [ "False" "True" ].
Extract Inlined Constant int => "Prelude.Int".
Extract Inlined Constant float => "Prelude.Float".

Extraction Library Datatypes.
Extraction Library LLVMAst.
