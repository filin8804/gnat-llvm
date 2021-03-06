------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020, AdaCore                          --
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

with LLVM.Core; use LLVM.Core;

with Debug;    use Debug;
with Get_Targ; use Get_Targ;
with Namet;
with Osint;    use Osint;
with Osint.C;  use Osint.C;
with Output;   use Output;

with GNATLLVM; use GNATLLVM;

with CCG.Output;      use CCG.Output;
with CCG.Subprograms; use CCG.Subprograms;

package body CCG is

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLLVM.

   ---------------------------
   --  Initialize_C_Writing --
   ---------------------------

   procedure Initialize_C_Writing is
   begin
      --  Initialize the sizes of integer types.

      Char_Size      := Get_Char_Size;
      Short_Size     := Get_Short_Size;
      Int_Size       := Get_Int_Size;
      Long_Size      := Get_Long_Size;
      Long_Long_Size := Get_Long_Long_Size;
   end Initialize_C_Writing;

   ------------------
   -- Write_C_Code --
   ------------------

   procedure Write_C_Code (Module : Module_T) is
      Func : Value_T := Get_First_Function (Module);
      Glob : Value_T := Get_First_Global (Module);

   begin
      --  If we're not writing to standard output, open the .c file

      if not Debug_Flag_Dot_YY then
         Namet.Unlock;
         Create_C_File;
         Set_Output (Output_FD);
         Namet.Lock;
      end if;

      --  Write out declarations for all globals with initializers

      while Present (Glob) loop
         if Present (Get_Initializer (Glob)) then
            Write_Decl (Glob);
         end if;

         Glob := Get_Next_Global (Glob);
      end loop;

      --  Process all functions, writing globals and typedefs on the fly
      --  and queueing the rest for later output.

      while Present (Func) loop
         Generate_C_For_Subprogram (Func);
         Func := Get_Next_Function (Func);
      end loop;

      --  Finally, write all the code we generated and close the .c file
      --  if we made one.

      Write_Subprograms;
      if not Debug_Flag_Dot_YY then
         Close_C_File;
         Set_Standard_Output;
      end if;
   end Write_C_Code;

end CCG;
