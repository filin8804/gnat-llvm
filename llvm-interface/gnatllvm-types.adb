------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2018, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Errout;   use Errout;
with Sem_Util; use Sem_Util;
with Sinfo;    use Sinfo;
with Stand;    use Stand;
with Uintp;    use Uintp;

with GNATLLVM.Arrays;  use GNATLLVM.Arrays;
with GNATLLVM.Compile; use GNATLLVM.Compile;
with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

package body GNATLLVM.Types is

   -----------------------
   -- Local Subprograms --
   -----------------------

   function Create_Subprogram_Type
     (Env           : Environ;
      Param_Ident   : Entity_Id;
      Return_Type   : Entity_Id;
      Takes_S_Link  : Boolean) return Type_T
     with Pre  => Env /= null and then Present (Param_Ident)
                  and then Is_Type_Or_Void (Return_Type),
          Post => Present (Create_Subprogram_Type'Result);
   --  Helper for public Create_Subprogram_Type functions: the public
   --  ones harmonize input and this one actually creates the LLVM
   --  type for subprograms.  Return_Type will be of Ekind E_Void if
   --  this is a procedure.

   function Create_Subprogram_Access_Type
     (Env       : Environ;
      Subp_Type : Type_T) return Type_T
     with Pre  => Env /= null and then Present (Subp_Type),
          Post => Present (Create_Subprogram_Access_Type'Result);
   --  Return a structure type that embeds Subp_Type and a static link pointer

   function Rec_Comp_Filter (E : Entity_Id) return Boolean is
     (Ekind (E) in E_Component | E_Discriminant);

   function Iterate_Components is new Iterate_Entities
     (Get_First => First_Entity,
      Get_Next  => Next_Entity,
      Filter    => Rec_Comp_Filter);
   --  Iterate over all components of a given record type

   ------------
   -- Int_Ty --
   ------------

   function Int_Ty (Num_Bits : Natural) return Type_T is
      (Int_Type (unsigned (Num_Bits)));

   -----------
   -- Fn_Ty --
   -----------

   function Fn_Ty (Param_Ty : Type_Array; Ret_Ty : Type_T) return Type_T is
     (Function_Type
       (Ret_Ty, Param_Ty'Address, Param_Ty'Length, False));

   ---------------------------
   -- Build_Type_Conversion --
   ---------------------------

   function Build_Type_Conversion
     (Env : Environ; Dest_Type : Entity_Id; Expr : Node_Id) return GL_Value
   is
   begin

      --  If both types are elementary, hand that off to our helper.

      if Is_Elementary_Type (Full_Etype (Expr))
        and then Is_Elementary_Type (Dest_Type)
      then
         return Convert_To_Elementary_Type (Env,
                                            Emit_Expression (Env, Expr),
                                            Dest_Type);

      --  Otherwise, we do the same as an unchecked conversion.

      else
         return Build_Unchecked_Conversion (Env, Dest_Type, Expr);

      end if;
   end Build_Type_Conversion;

   ---------------------------------
   -- Convert_To_Elementary_Types --
   ---------------------------------

   function Convert_To_Elementary_Type
     (Env : Environ; G : GL_Value; D_Type : Entity_Id) return GL_Value
   is
      type Cvtf is access function
        (Env : Environ; Value : GL_Value; TE : Entity_Id; Name : String := "")
        return GL_Value;

      Value       : GL_Value         := G;
      LLVM_Type   : constant Type_T  := Create_Type (Env, D_Type);
      Src_Access  : constant Boolean := Is_Access_Type (Value);
      Dest_Access : constant Boolean := Is_Access_Type (D_Type);
      Src_FP      : constant Boolean := Is_Floating_Point_Type (Value);
      Dest_FP     : constant Boolean := Is_Floating_Point_Type (D_Type);
      Src_Uns     : constant Boolean := Is_Unsigned_Type (Value);
      Dest_Uns    : constant Boolean := Is_Unsigned_Type (Value);
      Src_Size    : constant unsigned_long_long :=
        Get_LLVM_Type_Size_In_Bits (Env, Value);
      Dest_Usize  : constant Uint :=
        (if Is_Modular_Integer_Type (D_Type) then RM_Size (D_Type)
         else Esize (D_Type));
      Dest_Size   : constant unsigned_long_long :=
        unsigned_long_long (UI_To_Int (Dest_Usize));
      Is_Trunc    : constant Boolean := Dest_Size < Src_Size;
      Subp        : Cvtf := null;
   begin

      --  If the value is already of the desired LLVM type, we're done.

      if Type_Of (Value) = LLVM_Type then
         return Value;

      --  If converting pointer to/from integer, copy the bits using the
      --  appropriate instruction.

      elsif Dest_Access and then Is_Integer_Type (Value) then
         Subp := Int_To_Ptr'Access;
      elsif Is_Integer_Type (D_Type) and then Src_Access then
         Subp := Ptr_To_Int'Access;

      --  For pointer to pointer, call our helper

      elsif Src_Access and then Dest_Access then
         return Convert_To_Access_To
           (Env, Value, Full_Designated_Type (D_Type));

      --  Having dealt with pointers, we have four cases: FP to FP, FP to
      --  Int, Int to FP, and Int to Int.  We already know that this isn't
      --  a noop case because we've checked above for the same type.

      elsif Src_FP and then Dest_FP then
         Subp := (if Is_Trunc then FP_Trunc'Access else FP_Ext'Access);

      elsif Src_FP and then not Dest_FP then
         Subp := (if Dest_Uns then FP_To_UI'Access else FP_To_SI'Access);

         --  In the FP to Integer case, the LLVM instructions round to
         --  zero, but the Ada semantics round away from zero, so we have
         --  to adjust the input.  We first compute Type'Pred (0.5).  If
         --  the input is strictly negative, subtract this value and
         --  otherwise add it from the input.  For 0.5, the result is
         --  exactly between 1.0 and the machine number preceding 1.0.
         --  Since the last bit of 1.0 is even, this 0.5 will round to 1.0,
         --  while all other number with an absolute value less than 0.5
         --  round to 0.0.  For larger numbers exactly halfway between
         --  integers, rounding will always be correct as the true
         --  mathematical result will be closer to the higher integer
         --  compared to the lower one.  So, this constant works for all
         --  floating-point numbers.

         --  The reason to use the same constant with subtract/add instead
         --  of a positive and negative constant is to allow the comparison
         --  to be scheduled in parallel with retrieval of the constant and
         --  conversion of the input to the calc_type (if necessary).

         --  The easiest way of computing the constant is to do it at
         --  compile-time by finding the correct floating-point type to use.

         declare
            Size_In_Bits : constant unsigned_long_long :=
              Get_LLVM_Type_Size_In_Bits (Env, Value);
            PredHalf     : constant Long_Long_Float :=
              (if Long_Long_Float'Size = Size_In_Bits
               then Long_Long_Float'Pred (0.5)
               elsif Long_Float'Size = Size_In_Bits
               then Long_Long_Float (Long_Float'Pred (0.5))
               elsif Float'Size = Size_In_Bits
               then Long_Long_Float (Float'Pred (0.5))
               else Long_Long_Float (Short_Float'Pred (0.5)));
            Val_Neg    : constant GL_Value :=
              F_Cmp (Env, Real_OLT, Value, Const_Real (Env, Value, 0.0));
            Adjust_Amt : constant GL_Value :=
                Const_Real (Env, Value, double (PredHalf));
            --  ?? The conversion to "double" above may be problematic,
            --  but it's not clear how else to get the constant to LLVM.

            Add_Amt    : constant GL_Value :=
                F_Add (Env, Value, Adjust_Amt, "round-add");
            Sub_Amt    : constant GL_Value :=
                F_Sub (Env, Value, Adjust_Amt, "round-sub");

         begin
            Value := Build_Select (Env, Val_Neg, Sub_Amt, Add_Amt);
         end;

      elsif not Src_FP and then Dest_FP then
         Subp := (if Src_Uns then UI_To_FP'Access else SI_To_FP'Access);

      --  Remaining case is integer to integer.

      elsif Is_Trunc then
         Subp := Trunc'Access;
      else
         Subp := (if Src_Uns then Z_Ext'Access else S_Ext'Access);
      end if;

      --  Here all that's left to do is generate the IR instruction.

      return Subp (Env, Value, D_Type);

   end Convert_To_Elementary_Type;

   --------------------------
   -- Convert_To_Access_Of --
   --------------------------

   function Convert_To_Access_To
     (Env : Environ; Src : GL_Value; Desig_Type : Entity_Id) return GL_Value
   is
      Unc_Src  : constant Boolean := Is_Access_Unconstrained (Src);
      Unc_Dest : constant Boolean :=
        Is_Array_Type (Desig_Type) and then not Is_Constrained (Desig_Type);
   begin

      --  If neither is constrained, but they aren't the same type, just do
      --  a pointer cast.  If both are constrained, we return the input
      --  unchanged (the front end is responsible for this making sense).
      --  Otherwise, we have to handle converting between fat and raw
      --  pointers.

      if not Unc_Src and not Unc_Dest then
         if Full_Designated_Type (Src) = Desig_Type then
            return Src;
         else
            return Ptr_To_Ref (Env, Src, Desig_Type);
         end if;

      elsif Unc_Src and then Unc_Dest then
         return Src;

      elsif Unc_Src and then not Unc_Dest then
         return Convert_To_Access_To (Env, Array_Data (Env, Src), Desig_Type);
      else
         pragma Assert (not Unc_Src and then Unc_Dest);
         return Array_Fat_Pointer (Env, Desig_Type, Src);
      end if;
   end Convert_To_Access_To;

   --------------------------------
   -- Build_Unchecked_Conversion --
   --------------------------------

   function Build_Unchecked_Conversion
     (Env : Environ; Dest_Type : Entity_Id; Expr : Node_Id) return GL_Value
   is
      type Opf is access function
        (Env : Environ; V : GL_Value; TE : Entity_Id; Name : String)
        return GL_Value;

      Dest_Ty   : constant Type_T := Create_Type (Env, Dest_Type);
      Value     : constant GL_Value := Emit_Expression (Env, Expr);
      Subp      : Opf := null;
   begin

      --  If the value is already of the desired LLVM type, we're done.

      if Type_Of (Value) = Dest_Ty then
         return Value;

      --  Likewise if we're converting between two record types or two
      --  array types and this doesn't come from the source since these are
      --  UC's added by the front end for its type correctness, but which
      --  don't affect how we generate code.

      elsif not Comes_From_Source (Parent (Expr))
        and then ((Is_Record_Type (Dest_Type)
                     and then Is_Record_Type (Full_Etype (Expr)))
                  or else (Is_Array_Type (Dest_Type)
                             and then Is_Array_Type (Full_Etype (Expr))))
      then
         return Value;

      --  If converting pointer to pointer or pointer to/from integer, we
      --  just copy the bits using the appropriate instruction.

      elsif Is_Access_Type (Dest_Type) and then Is_Scalar_Type (Value) then
         Subp := Int_To_Ptr'Access;
      elsif Is_Scalar_Type (Dest_Type) and then Is_Access_Type (Value) then
         Subp := Ptr_To_Int'Access;
      elsif Is_Access_Type (Value) and then Is_Access_Type (Dest_Type)
        and then not Is_Access_Unconstrained (Value)
        and then not Is_Access_Unconstrained (Dest_Type)
      then
         Subp := Pointer_Cast'Access;

      --  If these are both integral types, we handle this as a normal
      --  conversion.  Unchecked conversion is only defined if the sizes
      --  are the same, which is handled above by checking for the same
      --  LLVM type, but the front-end generates it, meaning to do
      --  a normal conversion.

      elsif Is_Discrete_Or_Fixed_Point_Type (Dest_Type)
        and then Is_Discrete_Or_Fixed_Point_Type (Value)
      then
         return Convert_To_Elementary_Type (Env, Value, Dest_Type);

      --  We can unchecked convert floating point of the same width
      --  (the only way that UC is formally defined) with a "bitcast"
      --  instruction.

      elsif ((Is_Floating_Point_Type (Dest_Type)
                and then Is_Discrete_Or_Fixed_Point_Type (Value))
             or else (Is_Discrete_Or_Fixed_Point_Type (Dest_Type)
                        and then Is_Floating_Point_Type (Value)))
        and then (unsigned_long_long'(Get_LLVM_Type_Size_In_Bits
                                        (Env, Dest_Ty)) =
                    unsigned_long_long'(Get_LLVM_Type_Size_In_Bits
                                          (Env, Value)))
      then
         return Bit_Cast (Env, Value, Dest_Type);

      --  Otherwise, these must be cases where we have to convert by
      --  pointer punning.  If the source is a type of dynamic size, the
      --  value is already a pointer.  Otherwise, we have to make it a
      --  pointer.  ??? This code has a problem in that it calls Emit_LValue
      --  on an expression that's already been elaborated, but let's fix
      --  that double-elaboration issue later.

      else
         declare
            Addr           : constant GL_Value :=
              (if Is_Dynamic_Size (Env, Value) then Value
               else Emit_LValue (Env, Expr));
         begin
            return Need_Value (Env,
                               Ptr_To_Ref (Env, Addr, Dest_Type,
                                           "unc-ptr-cvt"),
                               Dest_Type);
         end;
      end if;

      --  If we get here, we should have set Subp to point to the function
      --  to call to do the conversion.

      return Subp (Env, Value, Dest_Type, "unchecked-conv");
   end Build_Unchecked_Conversion;

   ------------------
   -- Count_Params --
   ------------------

   function Count_Params (E : Entity_Id) return Nat is
      Cnt   : Nat := 0;
      Param : Entity_Id := First_Formal_With_Extras (E);
   begin
      while Present (Param) loop
         Cnt := Cnt + 1;
         Param := Next_Formal_With_Extras (Param);
      end loop;

      return Cnt;
   end Count_Params;

   --------------------------------
   -- Get_LLVM_Type_Size_In_Bits --
   --------------------------------

   function Get_LLVM_Type_Size_In_Bits
     (Env : Environ; TE : Entity_Id) return GL_Value
   is
      LLVM_Type : constant Type_T := Create_Type (Env, TE);
   begin
      pragma Assert (not Is_Dynamic_Size (Env, TE));
      return Get_LLVM_Type_Size_In_Bits (Env, LLVM_Type);
   end Get_LLVM_Type_Size_In_Bits;

   ------------------------
   -- Create_Access_Type --
   ------------------------

   function Create_Access_Type
     (Env : Environ; TE : Entity_Id) return Type_T
   is
      T : constant Type_T := Create_Type (Env, TE);
   begin
      if Is_Array_Type (TE) and then not Is_Constrained (TE) then
         return Create_Array_Fat_Pointer_Type (Env, TE);
      else
         return Pointer_Type (T, 0);
      end if;
   end Create_Access_Type;

   -----------------------
   -- GNAT_To_LLVM_Type --
   -----------------------

   function GNAT_To_LLVM_Type
     (Env : Environ; TE : Entity_Id; Definition : Boolean) return Type_T
   is
      Def_Ident : Entity_Id;
      Typ       : Type_T := No_Type_T;
      TBAA      : Metadata_T := No_Metadata_T;
      Discard   : Type_T;
      pragma Unreferenced (Discard);
      pragma Unreferenced (Definition);
   begin
      --  See if we already have a type.  If so, we must not be defining
      --  this type.  ??? But we can't add that test just yet.

      Typ := Get_Type (Env, TE);
      if Present (Typ) then
         --  pragma Assert (not Definition);
         return Typ;
      end if;

      --  See if we can get the type from the fullest view.
      --  ??? This isn't quite right in the case where we're not
      --  defining the type, or where there's a Freeze_Node, but add this
      --  logic later.
      Def_Ident := Get_Fullest_View (TE);
      if Def_Ident /= TE then
         Typ := GNAT_To_LLVM_Type (Env, Def_Ident, False);
         if Present (Typ) then
            Copy_Type_Info (Env, Def_Ident, TE);
            return Typ;
         end if;
      end if;

      --  ??? This probably needs to be cleaned up, but before we do anything,
      --  see if this isn't a base type and process that if so.
      if Base_Type (Def_Ident) /= Def_Ident then
         Discard := GNAT_To_LLVM_Type (Env, Base_Type (Def_Ident), False);
      end if;

      case Ekind (Def_Ident) is
         when Discrete_Kind =>
            --  LLVM is expecting boolean expressions to be of size 1
            --  ??? will not work properly if there is a size clause

            if Is_Boolean_Type (Def_Ident) then
               Typ := Int_Type_In_Context (Env.Ctx, 1);
            elsif Is_Modular_Integer_Type (Def_Ident) then
               Typ := Int_Type_In_Context
                 (Env.Ctx,
                  unsigned (UI_To_Int (RM_Size (Def_Ident))));

            else
               Typ := Int_Type_In_Context
                 (Env.Ctx,
                  unsigned (UI_To_Int (Esize (Def_Ident))));
            end if;

         when E_Floating_Point_Type | E_Floating_Point_Subtype =>
            declare
               Float_Type : constant Node_Id
                 := Full_Etype (Full_Etype (Def_Ident));
               Size       : constant Uint := Esize (Float_Type);

            begin
               case Float_Rep (Float_Type) is
                  when IEEE_Binary =>
                     if Size = Uint_32 then
                        Typ := Float_Type_In_Context (Env.Ctx);
                     elsif Size = Uint_64 then
                        Typ := Double_Type_In_Context (Env.Ctx);
                     elsif Size = Uint_128 then
                        --  Extended precision; not IEEE_128
                        Typ := X86_F_P80_Type_In_Context (Env.Ctx);
                     else
                        pragma Assert (UI_Is_In_Int_Range (Size));

                        case UI_To_Int (Size) is
                           when 80 | 96 =>
                              Typ := X86_F_P80_Type_In_Context (Env.Ctx);
                           when others =>
                              --  ??? Double check that
                              Typ := F_P128_Type_In_Context (Env.Ctx);
                        end case;
                     end if;

                  when AAMP =>
                     --  Not supported
                     Error_Msg_N ("unsupported floating point type", TE);
                     Typ := Void_Type_In_Context (Env.Ctx);
               end case;
            end;

         when E_Access_Type .. E_General_Access_Type
            | E_Anonymous_Access_Type
            | E_Access_Subprogram_Type =>
            Typ := Create_Access_Type (Env, Full_Designated_Type (Def_Ident));

         when E_Anonymous_Access_Subprogram_Type =>
            Typ := Create_Subprogram_Access_Type
              (Env, Create_Type (Env, Full_Designated_Type (Def_Ident)));

         when Record_Kind =>
            declare
               Struct_Type   : Type_T;
               Comps         : constant Entity_Iterator :=
                 Iterate_Components (Def_Ident);
               LLVM_Comps    : array (1 .. Comps'Length) of Type_T;
               I             : Natural := 1;
               Struct_Num    : Nat := 1;
               Num_Fields    : Natural := 0;
               Info          : Record_Info;
               Fields        : Field_Info_Vectors.Vector;
               Current_Field : Field_Info;

               function New_Struct_Info return Struct_Info is
                 ((LLVM_Type => Struct_Type, Preceding_Fields => Fields));

            begin
               Struct_Type := Struct_Create_Named
                 (Env.Ctx, Get_Name (Def_Ident));
               Info.Structs.Append (New_Struct_Info);

               --  Records enable some "type recursivity", so store this one in
               --  the environment so that there is no infinite recursion when
               --  nested components reference it.

               Set_Type (Env, Def_Ident, Struct_Type);

               for Comp of Comps loop
                  LLVM_Comps (I) := Create_Type (Env, Full_Etype (Comp));
                  Current_Field :=
                    (Struct_Num, Nat (I - 1), Comp, LLVM_Comps (I));
                  Fields.Append (Current_Field);
                  Info.Fields.Include (Comp, Current_Field);
                  I := I + 1;
                  Num_Fields := Num_Fields + 1;

                  --  If we are on a component with a dynamic size,
                  --  we create a new struct type for the following components.

                  if Is_Dynamic_Size (Env, Full_Etype (Comp)) then
                     Info.Dynamic_Size := True;
                     Struct_Set_Body
                       (Struct_Type, LLVM_Comps'Address,
                        unsigned (I - 1), False);
                     I := 1;
                     Struct_Num := Struct_Num + 1;

                     Struct_Type := Struct_Create_Named
                       (Env.Ctx, Get_Name (Def_Ident) & Img (Struct_Num));
                     Info.Structs.Append (New_Struct_Info);
                  end if;
               end loop;

               Struct_Set_Body
                 (Struct_Type, LLVM_Comps'Address, unsigned (I - 1), False);
               Set_Record_Info (Env, Def_Ident, Info);
               Set_Dynamic_Size (Env, Def_Ident, Info.Dynamic_Size);
               Typ := Get_Type (Env, Def_Ident);
            end;

         when Array_Kind =>
            --  Handle packed arrays.
            if Present (Packed_Array_Impl_Type (Def_Ident)) then
               Typ := Create_Type (Env, Packed_Array_Impl_Type (Def_Ident));
               Copy_Type_Info (Env, Packed_Array_Impl_Type (Def_Ident),
                               Def_Ident);
            else
               Typ := Create_Array_Type (Env, Def_Ident);
            end if;

         when E_Subprogram_Type =>
            --  An anonymous access to a subprogram can point to any subprogram
            --  (nested or not), so it must accept a static link.

            Typ := Create_Subprogram_Type_From_Entity
              (Env, Def_Ident,
               Takes_S_Link => (Nkind (Associated_Node_For_Itype (TE))
                                  /= N_Full_Type_Declaration));

         when Fixed_Point_Kind =>
            Typ := Int_Type_In_Context
              (Env.Ctx, unsigned (UI_To_Int (Esize (Def_Ident))));

         when E_Incomplete_Type =>
            --  This is a taft amendment type, return a dummy type

            Typ := Void_Type_In_Context (Env.Ctx);

         when E_Private_Type
            | E_Private_Subtype
            | E_Limited_Private_Type
            | E_Limited_Private_Subtype
         =>
            Typ := Create_Type (Env, Full_Etype (Def_Ident));

         when others =>
            Error_Msg_N
              ("unsupported type kind: `"
               & Ekind (Def_Ident)'Image & "`", Def_Ident);
            raise Program_Error;
      end case;

      --  Now save the result, if we have one, and compute any TBAA
      --  information.
      if Present (Typ) then
         Set_Type (Env, TE, Typ);
         TBAA := Create_TBAA (Env, TE);
         if Present (TBAA) then
            Set_TBAA (Env, TE, TBAA);
         end if;
      end if;

      return Typ;
   end GNAT_To_LLVM_Type;

   -----------------
   -- Create_TBAA --
   -----------------

   function Create_TBAA (Env : Environ; TE : Entity_Id) return Metadata_T is
   begin
      if Ekind (TE) in E_Signed_Integer_Type  |
                       E_Modular_Integer_Type |
                       E_Floating_Point_Type
      then
         return Create_TBAA_Scalar_Type_Node
           (Env.MDBld, Get_Name (TE), Env.TBAA_Root);
      else
         return No_Metadata_T;
      end if;
   end Create_TBAA;

   --------------------------
   -- Create_Discrete_Type --
   --------------------------

   procedure Create_Discrete_Type
     (Env : Environ; TE : Entity_Id; TL : out Type_T; Low, High : out GL_Value)
   is
      SRange : constant Node_Id := Scalar_Range (TE);
   begin
      --  Delegate LLVM Type creation to Create_Type

      TL := Create_Type (Env, TE);

      --  Compute the bounds

      pragma Assert (Nkind (SRange) = N_Range);
      Low := Emit_Expression (Env, Low_Bound (SRange));
      High := Emit_Expression (Env, High_Bound (SRange));

   end Create_Discrete_Type;

   --------------------------------------
   -- Create_Subprogram_Type_From_Spec --
   --------------------------------------

   function Create_Subprogram_Type_From_Spec
     (Env : Environ; Subp_Spec : Node_Id) return Type_T
   is
      Def_Ident : constant Entity_Id := Defining_Entity (Subp_Spec);
   begin
      return Create_Subprogram_Type
        (Env, Def_Ident, Full_Etype (Def_Ident), False);
   end Create_Subprogram_Type_From_Spec;

   ----------------------------------------
   -- Create_Subprogram_Type_From_Entity --
   ----------------------------------------

   function Create_Subprogram_Type_From_Entity
     (Env           : Environ;
      Subp_Type_Ent : Entity_Id;
      Takes_S_Link  : Boolean) return Type_T is
   begin
      return Create_Subprogram_Type
        (Env, Subp_Type_Ent, Full_Etype (Subp_Type_Ent),
         Takes_S_Link);
   end Create_Subprogram_Type_From_Entity;

   ----------------------------
   -- Create_Subprogram_Type --
   ----------------------------

   function Create_Subprogram_Type
     (Env           : Environ;
      Param_Ident   : Entity_Id;
      Return_Type   : Entity_Id;
      Takes_S_Link  : Boolean) return Type_T
   is
      LLVM_Return_Typ : Type_T :=
        (if Ekind (Return_Type) = E_Void
         then Void_Type_In_Context (Env.Ctx)
         else Create_Type (Env, Return_Type));
      Orig_Arg_Count  : constant Nat := Count_Params (Param_Ident);
      Args_Count      : constant Nat :=
        Orig_Arg_Count + (if Takes_S_Link then 1 else 0) +
          (if Ekind (Return_Type) /= E_Void
             and then Is_Dynamic_Size (Env, Return_Type)
           then 1 else 0);
      Arg_Types       : Type_Array (1 .. Args_Count);
      Param_Ent       : Entity_Id := First_Formal_With_Extras (Param_Ident);
      J               : Nat := 1;
   begin
      --  First, Associate an LLVM type for each Ada subprogram parameter

      while Present (Param_Ent) loop
         declare
            Param_Type : constant Node_Id := Full_Etype (Param_Ent);
         begin
            --  If this is an out parameter, or a parameter whose type is
            --  unconstrained, take a pointer to the actual parameter.

            Arg_Types (J) :=
              (if Param_Needs_Ptr (Param_Ent)
               then Create_Access_Type (Env, Param_Type)
               else Create_Type (Env, Param_Type));
         end;

         J := J + 1;
         Param_Ent := Next_Formal_With_Extras (Param_Ent);
      end loop;

      --  Set the argument for the static link, if any

      if Takes_S_Link then
         Arg_Types (Orig_Arg_Count + 1) :=
           Pointer_Type (Int8_Type_In_Context (Env.Ctx), 0);
      end if;

      --  If the return type has dynamic size, we need to add a parameter
      --  to which we pass the address for the return to be placed in.

      if Ekind (Return_Type) /= E_Void
        and then Is_Dynamic_Size (Env, Return_Type)
      then
         Arg_Types (Arg_Types'Last) := Create_Access_Type (Env, Return_Type);
         LLVM_Return_Typ := Void_Type_In_Context (Env.Ctx);
      end if;

      return Fn_Ty (Arg_Types, LLVM_Return_Typ);
   end Create_Subprogram_Type;

   -----------------------------------
   -- Create_Subprogram_Access_Type --
   -----------------------------------

   function Create_Subprogram_Access_Type
     (Env       : Environ;
      Subp_Type : Type_T) return Type_T
   is
      pragma Unreferenced (Subp_Type);

      Void_Ptr : constant Type_T :=
        Pointer_Type (Int8_Type_In_Context (Env.Ctx), 0);
      Couple : constant Type_Array (1 .. 2) := (Void_Ptr, Void_Ptr);

   begin
      return Struct_Type_In_Context
        (Env.Ctx,
         Couple'Address, Couple'Length,
         Packed => False);
   end Create_Subprogram_Access_Type;

   -----------------------
   -- Allocate_For_Type --
   -----------------------

   function Allocate_For_Type
     (Env : Environ; TE : Entity_Id; Name : String := "") return GL_Value
   is
      Element_Typ : Entity_Id;
      Num_Elts    : GL_Value;
   begin

      --  We have three cases.  If the object is not of a dynamic size,
      --  we just do the alloca and that's all.

      if not Is_Dynamic_Size (Env, TE) then
         return Alloca (Env, TE, Name);
      end if;

      --  Otherwise, we have to do some sort of dynamic allocation.  If
      --  this is an array of a component that's not of dynamic size, then
      --  we can allocate an array of the component type corresponding to
      --  the array type and cast it to a pointer to the actual type.
      --  If not, we have to allocate it as an array of bytes.

      if Is_Array_Type (TE)
        and then not Is_Dynamic_Size (Env, Full_Component_Type (TE))
      then
         Element_Typ := Full_Component_Type (TE);
         Num_Elts    := Get_Array_Elements (Env, No_GL_Value, TE);
      else
         Element_Typ := Standard_Short_Short_Integer;
         Num_Elts    := Get_Type_Size (Env, TE, No_GL_Value);
      end if;

      return Ptr_To_Ref
        (Env,
         Array_Alloca (Env, Element_Typ, Num_Elts, "dyn-array"), TE, Name);

   end Allocate_For_Type;

   ---------------------------
   --  Convert_To_Size_Type --
   ---------------------------

   function Convert_To_Size_Type
     (Env : Environ; V : GL_Value) return GL_Value
   is
   begin
      return Convert_To_Elementary_Type (Env, V, Env.Size_Type);
   end Convert_To_Size_Type;

   -------------------
   -- Get_Type_Size --
   -------------------

   function Get_Type_Size
     (Env      : Environ;
      TE       : Entity_Id;
      V        : GL_Value;
      For_Type : Boolean := False) return GL_Value
   is
      Size           : GL_Value;
      Dynamic_Fields : Boolean := False;
      T              : constant Type_T := Create_Type (Env, TE);
   begin

      --  ?? Record types still use the old mechanism, so keep the old code
      --  and check first.

      if Is_Record_Type (TE) then
         Size := Get_LLVM_Type_Size (Env, T);

         if Record_With_Dynamic_Size (Env, TE) then
            for Comp of Iterate_Components (TE) loop
               if Is_Dynamic_Size (Env, Full_Etype (Comp)) then
                  Dynamic_Fields := True;
               end if;

               --  Compute size of all fields once we've found a dynamic
               --  component.

               if Dynamic_Fields then
                  Size := NSW_Add
                    (Env,
                     Size,
                     Get_Type_Size
                       (Env, Full_Etype (Comp), No_GL_Value, For_Type),
                     "record-size");
               end if;
            end loop;
         end if;

      elsif Is_Array_Type (TE) and then Is_Dynamic_Size (Env, TE) then
         declare
            Comp_Type     : constant Entity_Id := Full_Component_Type (TE);
            Comp_Size     : constant GL_Value :=
              Get_Type_Size (Env, Comp_Type, No_GL_Value, For_Type);
            Num_Elements  : constant GL_Value :=
              Get_Array_Elements (Env, V, TE, For_Type);
         begin
            Size := NSW_Mul
              (Env, Convert_To_Size_Type (Env, Comp_Size),
               Convert_To_Size_Type (Env, Num_Elements),
               "size");
         end;

      else
         Size := Get_LLVM_Type_Size (Env, T);
      end if;

      return Size;

   end Get_Type_Size;

   ------------------------------
   -- Get_Type_Size_Complexity --
   ------------------------------

   function Get_Type_Size_Complexity
     (Env      : Environ;
      TE       : Entity_Id) return Natural
   is
   begin

      if Is_Record_Type (TE) then

         --  For now, just distinguish dynamic and constant size.

         return (if Is_Dynamic_Size (Env, TE) then 10 else 0);

      elsif Is_Array_Type (TE) then

         return Get_Array_Size_Complexity (Env, TE);

      else

         --  All other types are constant size.

         return 0;

      end if;
   end Get_Type_Size_Complexity;

   -------------------------
   -- Record_Field_Offset --
   -------------------------

   function Record_Field_Offset
     (Env          : Environ;
      Record_Ptr   : Value_T;
      Record_Field : Node_Id) return Value_T
   is

      Type_Id    : constant Entity_Id :=
        Get_Fullest_View (Scope (Record_Field));
      R_Info     : constant Record_Info := Get_Record_Info (Env, Type_Id);
      F_Info     : constant Field_Info := R_Info.Fields.Element (Record_Field);
      Struct_Ptr : Value_T := Record_Ptr;

   begin
      if F_Info.Containing_Struct_Index > 1 then
         declare
            Int_Struct_Address : Value_T := Ptr_To_Int
              (Env.Bld,
               Record_Ptr, Int_Ptr_Type, "offset-calc");
            S_Info : constant Struct_Info :=
              R_Info.Structs (F_Info.Containing_Struct_Index);

         begin
            --  Accumulate the size of every field
            for Preceding_Field of S_Info.Preceding_Fields loop
               Int_Struct_Address := NSW_Add
                 (Env.Bld,
                  Int_Struct_Address,
                  Get_Type_Size
                    (Env,
                     Full_Etype (Preceding_Field.Entity), No_GL_Value).Value,
                  "offset-calc");
            end loop;

            Struct_Ptr := Int_To_Ptr
              (Env.Bld,
               Int_Struct_Address, Pointer_Type (S_Info.LLVM_Type, 0), "back");
         end;
      end if;

      return Struct_GEP
        (Env.Bld,
         Struct_Ptr, unsigned (F_Info.Index_In_Struct), "field_access");
   end Record_Field_Offset;

   ------------------------------
   -- Record_With_Dynamic_Size --
   ------------------------------

   function Record_With_Dynamic_Size
     (Env : Environ; T : Entity_Id) return Boolean
   is
      Full_View : constant Entity_Id := Get_Fullest_View (T);
      Unused    : Type_T;
   begin
      if Is_Record_Type (Full_View) then
         --  First ensure the type is created
         Unused := Create_Type (Env, Full_View);
         return Get_Record_Info (Env, Full_View).Dynamic_Size;
      else
         return False;
      end if;
   end Record_With_Dynamic_Size;

end GNATLLVM.Types;
