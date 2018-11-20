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

with Nlists;   use Nlists;
with Sem_Aggr; use Sem_Aggr;
with Sinfo;    use Sinfo;

with GNATLLVM.GLValue;     use GNATLLVM.GLValue;
with GNATLLVM.Types;       use GNATLLVM.Types;

package GNATLLVM.Arrays is

   function Contains_Discriminant (N : Node_Id) return Boolean;
   --  Return True if N contains a reference to a discriminant

   function Create_Array_Type
     (TE : Entity_Id; For_Orig : Boolean := False) return Type_T
     with Pre  => (if   For_Orig then Is_Packed_Array_Impl_Type (TE)
                   else Is_Array_Type (TE)),
          Post => Present (Create_Array_Type'Result);
   --  Return the type used to represent Array_Type_Node.  This will be
   --  an opaque type if LLVM can't represent it directly.  If For_Orig
   --  is True, set the array info for the Original_Record_Type of TE.

   function Create_Array_Fat_Pointer_Type (TE : Entity_Id) return Type_T
     with Pre  => Is_Array_Or_Packed_Array_Type (TE),
          Post => Present (Create_Array_Fat_Pointer_Type'Result);
   --  Return the type used to store fat pointers to Array_Type

   function Create_Array_Bounds_Type (TE : Entity_Id) return Type_T
     with Pre  => Is_Array_Or_Packed_Array_Type (TE),
          Post => Present (Create_Array_Bounds_Type'Result);
   --  Helper that returns the type used to store array bounds. This is a
   --  structure that that follows the following pattern: { LB0, UB0, LB1,
   --  UB1, ... }

   function Get_Bound_Size (TE : Entity_Id) return GL_Value
     with Pre  => Is_Array_Or_Packed_Array_Type (TE),
          Post => Present (Get_Bound_Size'Result);
   --  Get the size of the Bounds part of array and data of TE, taking into
   --  account both the size of the bounds and the alignment of the bounds
   --  and TE.

   function Bounds_To_Length
     (In_Low, In_High : GL_Value; TE : Entity_Id) return GL_Value
     with Pre  => Present (In_Low) and then Present (In_High)
                  and then Is_Type (TE)
                  and then Type_Of (In_Low) = Type_Of (In_High),
          Post => Full_Etype (Bounds_To_Length'Result) = TE;
   --  Low and High are bounds of a discrete type.  Compute the length of
   --  that type, taking into account the superflat case, and do that
   --  computation in TE.  We would like to have the above test be that the
   --  two types be identical, but that's too strict (for example, one
   --  may be Integer and the other Integer'Base), so just check the width.

   function Get_Bound_Alignment (TE : Entity_Id) return GL_Value
     with Pre  => Is_Array_Or_Packed_Array_Type (TE),
          Post => Full_Etype (Get_Bound_Alignment'Result) = Size_Type;
   --  Get the alignment of the Bounds part of array and data of TE

   function Get_Dim_Range (N : Node_Id) return Node_Id
     with Pre  => Present (N), Post => Present (Get_Dim_Range'Result);
   --  Return the N_Range for an array type

   function Get_Array_Bound
     (TE       : Entity_Id;
      Dim      : Nat;
      Is_Low   : Boolean;
      V        : GL_Value;
      Max_Size : Boolean := False;
      For_Orig : Boolean := False) return GL_Value
     with Pre  => Is_Array_Or_Packed_Array_Type (TE)
                  and then (Present (V) or else Is_Constrained (TE)
                              or else Max_Size),
          Post => Present (Get_Array_Bound'Result);
   --  Get the bound (lower if Is_Low, else upper) for dimension number
   --  Dim (0-origin) of an array whose LValue is Value and is of type
   --  Arr_Typ.  If For_Orig is True, get the information from
   --  Original_Array_Type of TE.

   function Get_Array_Length
     (TE      : Entity_Id;
      Dim     : Nat;
      V       : GL_Value;
      Max_Size : Boolean := False) return GL_Value
     with Pre  => Is_Array_Type (TE) and then Dim < Number_Dimensions (TE)
                  and then (Present (V) or else Is_Constrained (TE)
                              or else Max_Size),
          Post => Type_Of (Get_Array_Length'Result) = LLVM_Size_Type;
   --  Similar, but get the length of that dimension of the array.  This is
   --  always Size_Type's width, but may actually be a different GNAT type.

   function Get_Array_Size_Complexity
     (TE : Entity_Id; Max_Size : Boolean := False) return Nat
     with Pre => Is_Array_Type (TE);
   --  Return the complexity of computing the size of an array.  This roughly
   --  gives the number of "things" needed to access to compute the size.
   --  This returns zero iff the array type is of a constant size.

   function Get_Indices
     (Indices : List_Id; V : GL_Value) return GL_Value_Array
     with Pre  => Is_Array_Type (Related_Type (V))
                  and then (List_Length (Indices) =
                              Number_Dimensions (Related_Type (V))),
          Post => (Get_Indices'Result'Length =
                     Number_Dimensions (Related_Type (V)) + 1);
   --  Given a list of indices and V, return a list where we've evaluated
   --  all the indices and subtracted the lower bounds of each dimension.
   --  This list consists of the constant zero followed by the indices.

   function Swap_Indices
     (Idxs : Index_Array; V : GL_Value) return Index_Array
     with Pre  => Is_Array_Type (Related_Type (V)),
          Post => Swap_Indices'Result'Length = Idxs'Length;
   --  Given a list of indices, swap them if V is a Fortran array

   function Get_Indexed_LValue
     (Idxs : GL_Value_Array; V : GL_Value) return GL_Value
     with Pre  => Is_Reference (V) and then Is_Array_Type (Related_Type (V))
                  and then (Idxs'Length =
                              Number_Dimensions (Related_Type (V)) + 1),
          Post => Present (Get_Indexed_LValue'Result);
   --  Get an LValue corresponding to indexing V by the list of indices
   --  in Idxs.  This list is the constant zero followed by the actual indices
   --  (i.e., with the lower bound already subtracted).

   function Get_Slice_LValue (TE : Entity_Id; V : GL_Value) return GL_Value
     with Pre  => Is_Array_Type (Full_Designated_Type (V))
                  and then Number_Dimensions (Full_Designated_Type (V)) = 1,
          Post => Present (Get_Slice_LValue'Result);
   --  Similar, but we get the position from the First_Index of TE

   function Get_Array_Elements
     (V        : GL_Value;
      TE       : Entity_Id;
      Max_Size : Boolean := False) return GL_Value
     with Pre  => Is_Array_Type (TE)
                  and then (Present (V) or else Is_Constrained (TE)
                              or else Max_Size),
          Post => Present (Get_Array_Elements'Result);
   --  Return the number of elements contained in an Array_Type object as an
   --  integer as large as a pointer for the target architecture. If it is an
   --  unconstrained array, Array_Descr must be an expression that evaluates
   --  to the array.

   function Get_Array_Type_Size
     (TE       : Entity_Id;
      V        : GL_Value;
      Max_Size : Boolean := False) return GL_Value
     with Pre  => Is_Array_Type (TE),
          Post => Present (Get_Array_Type_Size'Result);

   function IDS_Array_Type_Size
     (TE       : Entity_Id;
      V        : GL_Value;
      Max_Size : Boolean := False) return IDS
     with Pre  => Is_Array_Type (TE),
          Post => Present (IDS_Array_Type_Size'Result);

   function BA_Array_Type_Size
     (TE       : Entity_Id;
      V        : GL_Value;
      Max_Size : Boolean := False) return BA_Data
     with Pre  => Is_Array_Type (TE);

   function BA_Bounds_To_Length
     (In_Low, In_High : BA_Data; TE : Entity_Id) return BA_Data;

   procedure Emit_Others_Aggregate (LValue : GL_Value; N : Node_Id)
     with Pre => Present (LValue)
                 and then Nkind_In (N, N_Aggregate, N_Extension_Aggregate)
                 and then Is_Others_Aggregate (N);
   --  Use memset to do an aggregate assignment from N to LValue

   function Emit_Array_Aggregate
     (N              : Node_Id;
      Dims_Left      : Pos;
      Indices_So_Far : Index_Array;
      Value_So_Far   : GL_Value) return GL_Value
     with Pre  => Nkind_In (N, N_Aggregate, N_Extension_Aggregate)
                  and then Is_Array_Type (Full_Etype (N)),
               Post => Present (Emit_Array_Aggregate'Result);
   --  Emit an N_Aggregate which is an array, returning the GL_Value that
   --  contains the data.  Value_So_Far, if Present, is any of the array
   --  whose value we've accumulated so far.  Dims_Left says how many
   --  dimensions of the outer array type we still can recurse into.
   --  Indices_So_Far are the indices of any outer N_Aggregate expressions
   --  we went through.

   procedure Maybe_Store_Bounds
     (Dest, Src : GL_Value; Src_Type : Entity_Id; For_Unconstrained : Boolean)
     with Pre => Present (Dest) and then Is_Type (Src_Type);
   --  If the type of Dest is a nominal constrained type for an aliased
   --  unconstrained array or if For_Unconstrained is True and the type of
   --  Dest is an unconstrained array, store bounds into Dest, taking them
   --  from Src_Type and Src, if the latter is Present.

   function Get_Array_Bounds
     (TE, V_Type : Entity_Id; V : GL_Value) return GL_Value
     with Pre  => Is_Array_Or_Packed_Array_Type (TE)
                  and then Is_Array_Or_Packed_Array_Type (V_Type),
          Post => Present (Get_Array_Bounds'Result);
   --  Get the bounds of the array type V_Type using V if necessary.  TE
   --  is the type of the array we're getting the bounds for, in case they're
   --  different.

end GNATLLVM.Arrays;
