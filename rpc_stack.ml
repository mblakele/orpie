(*  Orpie -- a fullscreen RPN calculator for the console
 *  Copyright (C) 2003-2004  Paul Pelzl
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License, Version 2,
 *  as published by the Free Software Foundation.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 *  Please send bug reports, patches, etc. to Paul Pelzl at 
 *  <pelzlpj@eecs.umich.edu>.
 *)

(* rpc_stack.ml -- implementation of internal calculator stack that holds
 *                 multiple data types
 *
 * The stack is implemented as a dynamically-allocated array.  This approach
 * enables non-standard stack operations such as random access and cyclic rotation of
 * elements.
 *
 * Each stack element contains both data and string (option) representations
 * of the data.  There can be multiple string representations, corresponding to
 * line-oriented and fullscreen displays, four different bases, two
 * different angle modes, and two different complex representations.  The
 * string representations are created immediately when needed; if not
 * immediately needed, they will eventually be precomputed and filled in in by a 
 * background thread (unless conserve_memory = false).
 *
 * Note: arguably, the rendering functions belong with the interface code
 *       rather than with the stack code.  I may make this change at some
 *       point, to better abstract the interface away from the underlying
 *       calculator object.
 *)


open Big_int
open Big_int_str
open Printf

exception Stack_error of string

(* orpie_data_t values are returned by pop(), but the values
 * on the stack are in stack_data_t format *)
type orpie_data_t = | RpcInt of Big_int.big_int
                    | RpcFloatUnit of Units.unit_t
                    | RpcComplexUnit of Units.unit_t
                    | RpcFloatMatrixUnit of Gsl_matrix.matrix * Units.unit_t
                    | RpcComplexMatrixUnit of Gsl_matrix_complex.matrix *
                                              Units.unit_t
                    | RpcVariable of string

type stack_int_string_t   = {mutable i_bin_line : string option; 
                             mutable i_oct_line : string option;
                             mutable i_dec_line : string option; 
                             mutable i_hex_line : string option;
                             mutable i_bin_fs   : string option; 
                             mutable i_oct_fs   : string option;
                             mutable i_dec_fs   : string option; 
                             mutable i_hex_fs   : string option}
type stack_float_unit_string_t = {mutable fu : string option}
type stack_cmpx_unit_string_t  = {mutable c_rect    : string option;
                                  mutable c_pol_rad : string option;
                                  mutable c_pol_deg : string option}
type stack_fmat_unit_string_t  = {mutable fmat_line : string option;
                                  mutable fmat_fs   : string option}
type stack_cmat_string_t  = {mutable cmat_rect_line    : string option;
                             mutable cmat_pol_rad_line : string option;
                             mutable cmat_pol_deg_line : string option;
                             mutable cmat_rect_fs      : string option;
                             mutable cmat_pol_rad_fs   : string option;
                             mutable cmat_pol_deg_fs   : string option}
type stack_var_string_t   = {mutable v_line : string option;
                             mutable v_fs   : string option}

(* internal storage format of stack elements *)
type stack_data_t = | StackInt of Big_int.big_int * stack_int_string_t
                    | StackFloatUnit of Units.unit_t * stack_float_unit_string_t
                    | StackComplexUnit of Units.unit_t * stack_cmpx_unit_string_t
                    | StackFloatMatrixUnit of Gsl_matrix.matrix * Units.unit_t *
                                              stack_fmat_unit_string_t
                    | StackComplexMatrixUnit of Gsl_matrix_complex.matrix *
                                                Units.unit_t * stack_cmat_string_t
                    | StackVariable of string * stack_var_string_t

let raise_invalid s = raise (Invalid_argument s)

let orpie_data_of_stack_data (sd : stack_data_t) =
   match sd with
   |StackInt (ii, _)                   -> RpcInt ii
   |StackFloatUnit (fu, _)             -> RpcFloatUnit fu
   |StackComplexUnit (cc, _)           -> RpcComplexUnit cc
   |StackFloatMatrixUnit (fm, uu, _)   -> RpcFloatMatrixUnit (fm, uu)
   |StackComplexMatrixUnit (cm, uu, _) -> RpcComplexMatrixUnit (cm, uu)
   |StackVariable (vv, _)              -> RpcVariable vv

let stack_data_of_orpie_data (od : orpie_data_t) =
   match od with
   |RpcInt ii ->
      StackInt (ii, 
         {i_bin_line = None;
          i_oct_line = None;
          i_dec_line = None;
          i_hex_line = None;
          i_bin_fs   = None;
          i_oct_fs   = None;
          i_dec_fs   = None;
          i_hex_fs   = None})
   |RpcFloatUnit fu ->
      StackFloatUnit (fu,
         {fu = None})
   |RpcComplexUnit cc ->
      StackComplexUnit (cc, 
         {c_rect    = None;
          c_pol_rad = None;
          c_pol_deg = None})
   |RpcFloatMatrixUnit (fm, uu) ->
      StackFloatMatrixUnit (fm, uu, 
         {fmat_line = None;
          fmat_fs   = None})
   |RpcComplexMatrixUnit (cm, uu) ->
      StackComplexMatrixUnit (cm, uu,
         {cmat_rect_line    = None;
          cmat_pol_rad_line = None;
          cmat_pol_deg_line = None;
          cmat_rect_fs      = None;
          cmat_pol_rad_fs   = None;
          cmat_pol_deg_fs   = None})
   |RpcVariable vv ->
      StackVariable (vv, 
         {v_line = None;
          v_fs   = None})


let funit_of_float ff = {
   Units.coeff = {
      Complex.re = ff;
      Complex.im = 0.0
   };
   Units.factors = []
}

let cunit_of_cpx cc = {
   Units.coeff   = cc;
   Units.factors = []
}

let unorm uu = {
   Units.coeff   = Complex.one;
   Units.factors = uu.Units.factors
}

let has_units fu =
   fu.Units.factors <> []

type display_mode_t = | Line | Fullscreen

type angle_mode   = | Rad | Deg
type base_mode    = | Bin | Oct | Hex | Dec
type complex_mode = | Rect | Polar
      
type calculator_modes = {angle : angle_mode; base : base_mode; 
                         complex : complex_mode}

let size_inc = 100
let pi = 3.14159265358979323846

class rpc_stack =
   object(self)
      val mutable len = 0
      val mutable stack = Array.make size_inc (stack_data_of_orpie_data
      (RpcFloatUnit (funit_of_float 0.0)))
      val render_stack = Stack.create ()


      method length = len


      (* save to a datafile using the Marshal module *)
      method save_state (modes : calculator_modes) 
      (variables : (string, orpie_data_t) Hashtbl.t) =
         try
            let version_file = Utility.join_path !(Rcfile.datadir) "version" in
            let version_channel = Utility.open_or_create_out_bin version_file in
            output_string version_channel Version.version;
            close_out version_channel;
            let save_file = Utility.join_path !(Rcfile.datadir) "calc_state" in
            let save_channel = Utility.open_or_create_out_bin save_file in
            Marshal.to_channel save_channel 
            (modes, variables, !Rcfile.autobind_keys, stack, len) [];
            close_out save_channel
         with
            |Sys_error ss -> raise (Invalid_argument "can't open data file for writing")
            |Failure ff   -> raise (Invalid_argument "can't serialize calculator data to file")

      (* load from a datafile using the Marshal module *)
      (* FIXME: if the datafile is corrupted, this can segfault... *)
      method load_state () =
         try
            (* check whether the version file exists *)
            let version_file = Utility.join_path !(Rcfile.datadir) "version" in
            if Sys.file_exists (Utility.expand_file version_file) then begin
               (* if it does exist, try loading it *)
               let version_channel = 
                  Utility.expand_open_in_ascii version_file
               in
               let ver_string = input_line version_channel in
               close_in version_channel;
               (* if the version strings match, then assume it's okay to use
                * Marshal. *)
               if ver_string = Version.version then begin
                  (* check whether the state file exists *)
                  let datafile = Utility.join_path !(Rcfile.datadir) "calc_state" in
                  if Sys.file_exists (Utility.expand_file datafile) then begin
                     (* if it does exist, try loading it *)
                     let load_channel = Utility.expand_open_in_bin datafile in
                     let data_modes, data_variables, data_autobind_keys, data_stack, data_len = 
                        (Marshal.from_channel load_channel : calculator_modes * 
                        ((string, orpie_data_t) Hashtbl.t) * 
                        (int * string * Operations.operation_t option * int) array *
                        (stack_data_t array) * int)
                     in
                     close_in load_channel;
                     stack <- data_stack;
                     len <- data_len;
                     Rcfile.validate_saved_autobindings data_autobind_keys;
                     data_modes, data_variables
                  end else
                     (* if the datafile is missing, do nothing as it will be
                      * created later *)
                     ({angle = Rad; base = Dec; complex = Rect}, Hashtbl.create 20)
               end else
                  (* if the version strings don't match, don't try loading anything *)
                  ({angle = Rad; base = Dec; complex = Rect}, Hashtbl.create 20)
            end else
               (* if the version file does not exist, don't try loading anything *)
                  ({angle = Rad; base = Dec; complex = Rect}, Hashtbl.create 20)
         with
            (* this gets raised if, for example, we don't have read permission
             * on the state data file *)
            |Sys_error ss -> raise (Invalid_argument "can't open calculator state data file")
            (* this shouldn't happen unless the data file gets corrupted. *)
            |Failure ff -> raise (Invalid_argument "can't deserialize calculator data from file")

            
      method backup () =
         let b_stack = Array.copy stack 
         and b_len = len in
         {< len = b_len; stack = b_stack >}



      method private expand_size () =
         (* allocate a new stack if necessary *)
         if len >= Array.length stack then begin
            let new_stack = Array.make ((Array.length stack) + size_inc)
            (stack_data_of_orpie_data (RpcFloatUnit 
            (Units.unit_of_float_string 0.0 ""))) in
            Array.blit stack 0 new_stack 0 (Array.length stack);
            stack <- new_stack
         end else
            ()


      method push (v : orpie_data_t) =
         self#expand_size ();
         let new_el = stack_data_of_orpie_data v in
         stack.(len) <- new_el;
         len <- len + 1;
         if !Rcfile.conserve_memory then ()
         else Stack.push new_el render_stack


      method pop () =
         (* compact stack memory by size_inc whenever we have 2 * size_inc
          * elements free *)
         if len < (Array.length stack) - 2 * size_inc then
            let new_stack = Array.sub stack 0 ((Array.length stack) -
            size_inc) in
            stack <- new_stack
         else
            ();
         let pop_result =
            if len > 0 then begin
               len <- len - 1;
               orpie_data_of_stack_data stack.(len)
            end else
               raise (Stack_error "cannot pop empty stack");
         in
         pop_result



      (* duplicate the top stack element *)
      method dup () =
         self#expand_size ();
         if len > 0 then begin
            stack.(len) <- stack.(pred len);
            len <- succ len
         end else
            raise (Stack_error "cannot dup with empty stack")

         
      (* swap the top two stack elements *)
      method swap () =
         if len > 1 then begin
            let temp = ref stack.(pred len) in
            stack.(pred len) <- stack.(len - 2);
            stack.(len - 2) <- !temp
         end else
            raise (Stack_error "cannot swap with less than two elements")


      (* copy a stack element to the top of the stack *)
      method echo el_num =
         self#expand_size ();
         if el_num <= len then begin
            let actual_el_num = len - el_num in
            stack.(len) <- stack.(actual_el_num);
            len <- succ len
         end else
            raise (Invalid_argument "cannot echo nonexistant element")


      (* cyclically roll all stack elements downward (i.e. towards the top
       * of the stack), starting below element number 'num' (inclusive). *)
      method rolldown num =
         if num <= len then
            let temp = stack.(pred len) in
            for i = pred len downto len - num + 1 do
               stack.(i) <- stack.(pred i)
            done;
            stack.(len - num) <- temp
         else
            raise (Stack_error "insufficient stack elements");


      (* cyclically roll all stack elements upward (i.e. away from the top
       * of the stack), starting below element number 'num' (inclusive). *)
      method rollup num =
         if num <= len then
            let temp = stack.(len - num) in
            for i = len - num to len - 2 do
               stack.(i) <- stack.(succ i)
            done;
            stack.(pred len) <- temp
         else
            raise (Stack_error "insufficient stack elements");


      (* delete a particular element *)
      method delete num =
         if num <= len then
            (for i = (len - num) to len do
               stack.(i) <- stack.(succ i)
            done;
            len <- (pred len))
         else
            raise (Stack_error "insufficient stack elements");



      (* delete all elements below level N *)
      method deleteN num =
         if num <= len then
            len <- len - num
         else
            raise (Stack_error "insufficient stack elements");


      (* keep only a particular stack element *)
      method keep num =
         if num <= len then
            (stack.(0) <- stack.(len - num);
            len <- 1)
         else
            raise (Stack_error "insufficient stack elements");


      (* keep all elements below the selected (inclusive) *)
      method keepN num =
         if num <= len then begin
            for i = 0 to num - 1 do
               stack.(i) <- stack.(i + len - num)
            done;
            len <- num
         end else
            raise (Stack_error "insufficient stack elements");



      (* return a particular stack element without removing it from the stack *)
      (* element 1 points to the top of the stack *)
      method peek el_num =
         let peek_result =
            if el_num <= len then
               let actual_el_num = len - el_num in
               orpie_data_of_stack_data stack.(actual_el_num)
            else
               let s = Printf.sprintf "cannot access nonexistant stack element %d"
               el_num in
               raise (Stack_error s);
         in
         peek_result

      
      method private get_display_string_wrap disp_mode line_num calc_modes =
         if line_num > 0 then
            if line_num <= len then
               (* this is the actual index into the array *)
               let index = len - line_num in
               self#lookup_or_create_string disp_mode calc_modes index
            else (* line_num > len *)
               ""
         else (* line_num <= 0 *)
            raise (Stack_error ("cannot display nonexistent stack element " ^
               (string_of_int line_num)))


      (* lookup (or create) a line-oriented display string *)
      method get_display_string line_num calc_modes =
         self#get_display_string_wrap Line line_num calc_modes


      (* lookup (or create) a fullscreen-oriented display string *)
      method get_fullscreen_display_string line_num calc_modes =
         self#get_display_string_wrap Fullscreen line_num calc_modes






      (* perform a table lookup to obtain the string representation of
       * the desired stack element.  If the table lookup fails, then create
       * the representation. *)
      method private lookup_or_create_string disp_mode calc_modes index =
         let stack_el = stack.(index) in
         let lookup_result =
            begin match stack_el with
            |StackInt (ii, ii_str) ->
               let lookup_int_str record =
                  begin match record with
                  |None ->
                     self#create_int_string disp_mode calc_modes ii ii_str
                  |Some ss ->
                     ss
                  end
               in
               begin match disp_mode with
               |Line ->
                  begin match calc_modes.base with
                  |Bin -> lookup_int_str ii_str.i_bin_line
                  |Oct -> lookup_int_str ii_str.i_oct_line
                  |Dec -> lookup_int_str ii_str.i_dec_line
                  |Hex -> lookup_int_str ii_str.i_hex_line
                  end
               |Fullscreen ->
                  begin match calc_modes.base with
                  |Bin -> lookup_int_str ii_str.i_bin_fs
                  |Oct -> lookup_int_str ii_str.i_oct_fs
                  |Dec -> lookup_int_str ii_str.i_dec_fs
                  |Hex -> lookup_int_str ii_str.i_hex_fs
                  end
               end
            |StackFloatUnit (fu, fu_str) ->
               begin match fu_str.fu with
               |None ->
                  self#create_float_unit_string fu fu_str
               |Some ss ->
                  ss
               end
            |StackComplexUnit (cc, cc_str) ->
               let lookup_cmpx_str record =
                  begin match record with
                  |None ->
                     self#create_cmpx_unit_string calc_modes cc cc_str
                  |Some ss ->
                     ss
                  end
               in
               begin match calc_modes.complex with
               |Rect -> 
                  lookup_cmpx_str cc_str.c_rect
               |Polar ->
                  begin match calc_modes.angle with
                  |Rad -> lookup_cmpx_str cc_str.c_pol_rad
                  |Deg -> lookup_cmpx_str cc_str.c_pol_deg
                  end
               end
            |StackFloatMatrixUnit (fm, uu, fm_str) ->
               begin match disp_mode with
               |Line ->
                  begin match fm_str.fmat_line with
                  |None ->
                     self#create_fmat_unit_string disp_mode fm uu fm_str
                  |Some ss ->
                     ss
                  end
               |Fullscreen ->
                  begin match fm_str.fmat_fs with
                  |None ->
                     self#create_fmat_unit_string disp_mode fm uu fm_str
                  |Some ss ->
                     ss
                  end
               end
            |StackComplexMatrixUnit (cm, uu, cm_str) ->
               let lookup_cmat_str record =
                  begin match record with
                  |None ->
                     self#create_cmat_unit_string disp_mode calc_modes cm uu cm_str
                  |Some ss ->
                     ss
                  end
               in
               begin match disp_mode with
               |Line ->
                  begin match calc_modes.complex with
                  |Rect ->
                     lookup_cmat_str cm_str.cmat_rect_line
                  |Polar ->
                     begin match calc_modes.angle with
                     |Rad -> lookup_cmat_str cm_str.cmat_pol_rad_line
                     |Deg -> lookup_cmat_str cm_str.cmat_pol_deg_line
                     end
                  end
               |Fullscreen ->
                  begin match calc_modes.complex with
                  |Rect ->
                     lookup_cmat_str cm_str.cmat_rect_fs
                  |Polar ->
                     begin match calc_modes.angle with
                     |Rad -> lookup_cmat_str cm_str.cmat_pol_rad_fs
                     |Deg -> lookup_cmat_str cm_str.cmat_pol_deg_fs
                     end
                  end
               end
            |StackVariable (vv, vv_str) ->
               begin match disp_mode with
               |Line ->
                  begin match vv_str.v_line with
                  |None ->
                     self#create_var_string disp_mode vv vv_str
                  |Some ss ->
                     ss
                  end
               |Fullscreen ->
                  begin match vv_str.v_fs with
                  |None ->
                     self#create_var_string disp_mode vv vv_str
                  |Some ss ->
                     ss
                  end
               end
            end;
         in
         lookup_result


      (* render all string representations of a particular stack element. *)
      method private render_all_strings stack_el =
         match stack_el with
         |StackInt (ii, ii_str) ->
            let lookup_int_str d_mode c_mode record =
               begin match record with
               |None ->
                  let _ = self#create_int_string d_mode c_mode ii ii_str in ()
               |Some ss ->
                  ()
               end
            in
            lookup_int_str Line {angle = Rad; base = Dec; complex = Rect} 
               ii_str.i_dec_line;
            lookup_int_str Line {angle = Rad; base = Bin; complex = Rect} 
               ii_str.i_bin_line;
            lookup_int_str Line {angle = Rad; base = Oct; complex = Rect} 
               ii_str.i_oct_line;
            lookup_int_str Line {angle = Rad; base = Hex; complex = Rect} 
               ii_str.i_hex_line
            (* the remaining integer strings will get filled in as
             * side-effects of the previous *)
         |StackFloatUnit (fu, fu_str) ->
            begin match fu_str.fu with
            |None ->
               let _ = self#create_float_unit_string fu fu_str in ()
            |Some ss ->
               ()
            end
         |StackComplexUnit (cc, cc_str) ->
            let lookup_cmpx_str c_mode record =
               begin match record with
               |None ->
                  let _ = self#create_cmpx_unit_string c_mode cc cc_str in ()
               |Some ss ->
                  ()
               end
            in
            lookup_cmpx_str {angle = Rad; base = Dec; complex = Rect} 
               cc_str.c_rect;
            lookup_cmpx_str {angle = Rad; base = Dec; complex = Polar} 
               cc_str.c_pol_rad;
            lookup_cmpx_str {angle = Deg; base = Dec; complex = Polar} 
               cc_str.c_pol_deg
         |StackFloatMatrixUnit (fm, uu, fm_str) ->
            begin match fm_str.fmat_line with
            |None ->
               let _ = self#create_fmat_unit_string Line fm uu fm_str in ()
            |Some ss ->
               ()
            end;
            begin match fm_str.fmat_fs with
            |None ->
               let _ = self#create_fmat_unit_string Fullscreen fm uu fm_str in ()
            |Some ss ->
               ()
            end
         |StackComplexMatrixUnit (cm, uu, cm_str) ->
            let lookup_cmat_str d_mode c_mode record =
               begin match record with
               |None ->
                  let _ = self#create_cmat_unit_string d_mode c_mode cm uu cm_str in ()
               |Some ss ->
                  ()
               end
            in
            lookup_cmat_str Line {angle = Rad; base = Dec; complex = Rect}
               cm_str.cmat_rect_line;
            lookup_cmat_str Line {angle = Rad; base = Dec; complex = Polar}
               cm_str.cmat_pol_rad_line;
            lookup_cmat_str Line {angle = Deg; base = Dec; complex = Polar}
               cm_str.cmat_pol_deg_line;
            lookup_cmat_str Fullscreen {angle = Rad; base = Dec; complex = Rect}
               cm_str.cmat_rect_fs;
            lookup_cmat_str Fullscreen {angle = Rad; base = Dec; complex = Polar}
               cm_str.cmat_pol_rad_fs;
            lookup_cmat_str Fullscreen {angle = Deg; base = Dec; complex = Polar}
               cm_str.cmat_pol_deg_fs
         |StackVariable (vv, vv_str) ->
            begin match vv_str.v_line with
            |None ->
               let _ = self#create_var_string Line vv vv_str in ()
            |Some ss ->
               ()
            end
            (* fullscreen is filled in as side-effect of previous *)



      (* generate the string representation for an integer, taking into
       * account the desired display mode and base.  Fullscreen and line
       * representations are computed concurrently because they share
       * most of the computation. *)
      method private create_int_string disp_mode calc_modes ii ii_str =
         match calc_modes.base with
         |Bin ->
            let s = string_of_big_int_base ii 2 in
            let line = "# " ^ s ^ "`b"
            and fs   = "#" ^ s ^ "`b" in
            if !Rcfile.conserve_memory then () else begin
               ii_str.i_bin_line <- Some line;
               ii_str.i_bin_fs   <- Some fs
            end;
            begin match disp_mode with
            |Line       -> line
            |Fullscreen -> fs
            end
         |Oct ->
            let s = string_of_big_int_base ii 8 in
            let line = "# " ^ s ^ "`o"
            and fs   = "#" ^ s ^ "`o" in
            if !Rcfile.conserve_memory then () else begin
               ii_str.i_oct_line <- Some line;
               ii_str.i_oct_fs   <- Some fs
            end;
            begin match disp_mode with
            |Line       -> line
            |Fullscreen -> fs
            end
         |Hex ->
            let s = string_of_big_int_base ii 16 in
            let line = "# " ^ s ^ "`h"
            and fs   = "#" ^ s ^ "`h" in
            if !Rcfile.conserve_memory then () else begin
               ii_str.i_hex_line <- Some line;
               ii_str.i_hex_fs   <- Some fs
            end;
            begin match disp_mode with
            |Line       -> line
            |Fullscreen -> fs
            end
         |Dec ->
            let s = string_of_big_int_base_gen ii 10 in
            let line = "# " ^ s ^ "`d"
            and fs   = "#" ^ s ^ "`d" in
            if !Rcfile.conserve_memory then () else begin
               ii_str.i_dec_line <- Some line;
               ii_str.i_dec_fs   <- Some fs
            end;
            begin match disp_mode with
            |Line       -> line
            |Fullscreen -> fs
            end


      (* generate a string representation for a floating-point value with a unit *)
      method private create_float_unit_string fu fu_str =
         let s = 
            if fu.Units.factors <> [] then
               sprintf "%.15g_%s" fu.Units.coeff.Complex.re 
               (Units.string_of_unit fu.Units.factors)
            else
               sprintf "%.15g" fu.Units.coeff.Complex.re 
         in
         if !Rcfile.conserve_memory then () 
         else fu_str.fu <- Some s;
         s


      (* generate a string representation for a complex value, taking
       * into account the representation mode and angle mode of the calc *)
      method private create_cmpx_unit_string calc_modes cc cc_str =
         let append_units ss =
            if cc.Units.factors <> [] then
               ss ^ "_" ^ (Units.string_of_unit cc.Units.factors)
            else
               ss
         in
         match calc_modes.complex with
         |Rect ->
            let s = append_units 
            (sprintf "(%.15g, %.15g)" cc.Units.coeff.Complex.re 
            cc.Units.coeff.Complex.im) in
            if !Rcfile.conserve_memory then () 
            else cc_str.c_rect <- Some s;
            s
         |Polar ->
            let r = sqrt (cc.Units.coeff.Complex.re *. cc.Units.coeff.Complex.re +.
            cc.Units.coeff.Complex.im *. cc.Units.coeff.Complex.im)
            and theta = atan2 cc.Units.coeff.Complex.im 
            cc.Units.coeff.Complex.re in
            begin match calc_modes.angle with
            |Rad ->
               let s = append_units (sprintf "(%.15g <%.15g)" r theta) in
               if !Rcfile.conserve_memory then () 
               else cc_str.c_pol_rad <- Some s;
               s
            |Deg ->
               let s = append_units 
               (sprintf "(%.15g <%.15g)" r (180.0 /. pi *. theta)) in
               if !Rcfile.conserve_memory then () 
               else cc_str.c_pol_deg <- Some s;
               s
            end


      (* generate a string representation for a floating-point matrix,
       * taking into account the display mode. *)
      method private create_fmat_unit_string disp_mode fm uu fm_str =
         let append_units ss = 
            if has_units uu then
               ss ^ "_" ^ Units.string_of_unit uu.Units.factors
            else
               ss
         in
         match disp_mode with
         |Line ->
            let s = 
               (* looks like [[ a11, a12 ][ a21, a22 ]] *)
               let rows, cols = (Gsl_matrix.dims fm) in
               let initial_string = "[" in
               let line = ref initial_string in
               for n = 0 to rows - 1 do
                  line := !line ^ "[ ";
                  for m = 0 to cols - 2 do
                     line := !line ^ (sprintf "%.15g, " fm.{n, m})
                  done;
                  line := !line ^ (sprintf "%.15g ]" fm.{n, cols-1})
               done;
               line := !line ^ "]";
               !line
            in
            let ss = append_units s in
            if !Rcfile.conserve_memory then () 
            else fm_str.fmat_line <- Some ss;
            ss
         |Fullscreen ->
            let s =
               (* looks like [[ a11, a12 ]
                *             [ a21, a22 ]] 
                * and the columns are aligned. *)
               let rows, cols = (Gsl_matrix.dims fm) in
               (* first get the maximum field width for each column *)
               let max_width = Array.make cols 0 in
               for m = 0 to pred cols do
                  for n = 0 to pred rows do
                     let dummy_string = sprintf "%-.15g" fm.{n, m} in
                     let ds_len = String.length dummy_string in
                     if ds_len > max_width.(m) then
                        max_width.(m) <- ds_len
                     else
                        ()
                  done
               done;
               (* now use the maximum field widths to align the columns
                * during string creation *)
               let initial_string = "[" in
               let line = ref initial_string in
               for n = 0 to rows - 1 do
                  line := !line ^ "[ ";
                  for m = 0 to cols - 2 do
                     line := !line ^ (sprintf "%*.15g, " max_width.(m) fm.{n, m})
                  done;
                  line := !line ^ (sprintf "%*.15g ]" max_width.(cols-1) fm.{n, cols-1});
                  if n < pred rows then
                     line := !line ^ "\n "
                  else
                     ()
               done;
               line := !line ^ "]";
               !line
            in
            let ss = append_units s in
            if !Rcfile.conserve_memory then () 
            else fm_str.fmat_fs <- Some ss;
            ss



      (* generate a string representation for a complex matrix,
       * taking into account the display mode. *)
      method private create_cmat_unit_string disp_mode calc_modes cm uu cm_str =
         let append_units ss = 
            if has_units uu then
               ss ^ "_" ^ Units.string_of_unit uu.Units.factors
            else
               ss
         in
         match disp_mode with
         |Line ->
            let s = 
               (* looks like [[ (a11re, a11im), (a12re, a12im) ][ (a21re,
                  a21im), (a22re, a22im) ] *)
               let rows, cols = (Gsl_matrix_complex.dims cm) in
               let initial_string = "[" in
               let line = ref initial_string in
               for n = 0 to rows - 1 do
                  line := !line ^ "[ ";
                  for m = 0 to cols - 2 do
                     match calc_modes.complex with
                     |Rect ->
                        line := !line ^ (sprintf "(%.15g, %.15g), " 
                           cm.{n, m}.Complex.re cm.{n, m}.Complex.im)
                     |Polar ->
                        let rr = cm.{n, m}.Complex.re
                        and ii = cm.{n, m}.Complex.im in
                        let r = sqrt (rr *. rr +. ii *. ii)
                        and theta = atan2 ii rr in
                        begin match calc_modes.angle with
                        |Rad ->
                           line := !line ^ (sprintf "(%.15g <%.15g), " 
                           r theta)
                        |Deg ->
                           line := !line ^ (sprintf "(%.15g <%.15g), " 
                           r (180.0 /. pi *. theta))
                        end
                  done;
                  match calc_modes.complex with
                  |Rect ->
                     line := !line ^ (sprintf "(%.15g, %.15g) ]" 
                        cm.{n, cols-1}.Complex.re cm.{n, cols-1}.Complex.im)
                  |Polar ->
                     let rr = cm.{n, cols-1}.Complex.re
                     and ii = cm.{n, cols-1}.Complex.im in
                     let r = sqrt (rr *. rr +. ii *. ii)
                     and theta = atan2 ii rr in
                     begin match calc_modes.angle with
                     |Rad ->
                        line := !line ^ (sprintf "(%.15g <%.15g) ]" 
                        r theta)
                     |Deg ->
                        line := !line ^ (sprintf "(%.15g <%.15g) ]" 
                        r (180.0 /. pi *. theta))
                     end
               done;
               line := !line ^ "]";
               !line
            in
            let ss = append_units s in
            if !Rcfile.conserve_memory then 
               () 
            else
               begin match calc_modes.complex with
               |Rect ->
                  cm_str.cmat_rect_line <- Some ss;
               |Polar ->
                  begin match calc_modes.angle with
                  |Rad -> cm_str.cmat_pol_rad_line <- Some ss
                  |Deg -> cm_str.cmat_pol_deg_line <- Some ss
                  end
               end;
            ss
         |Fullscreen ->
            let s =
               (* looks like [[ (a11re, a11im), (a12re, a12im) ]
                *             [ (a21re, a21im), (a22re, a22im) ] 
                * with properly aligned columns *)
               let rows, cols = (Gsl_matrix_complex.dims cm) in
               (* first get the maximum field width for each column *)
               let max_width = Array.make_matrix cols 2 0 in
               for m = 0 to pred cols do
                  for n = 0 to pred rows do
                     match calc_modes.complex with
                     |Rect ->
                        let dummy_re = sprintf "%-.15g" cm.{n, m}.Complex.re in
                        let dr_len = String.length dummy_re in
                        if dr_len > max_width.(m).(0) then
                           max_width.(m).(0) <- dr_len
                        else
                           ();
                        let dummy_im = sprintf "%-.15g" cm.{n, m}.Complex.im in
                        let di_len = String.length dummy_im in
                        if di_len > max_width.(m).(1) then
                           max_width.(m).(1) <- di_len
                        else
                           ()
                     |Polar ->
                        let rr = cm.{n, m}.Complex.re
                        and ii = cm.{n, m}.Complex.im in
                        let r = sqrt (rr *. rr +. ii *. ii)
                        and theta = atan2 ii rr in
                        let dummy_r = sprintf "%-.15g" r in
                        let r_len = String.length dummy_r in
                        if r_len > max_width.(m).(0) then
                           max_width.(m).(0) <- r_len
                        else
                           ();
                        let dummy_theta = 
                           match calc_modes.angle with
                           |Rad -> sprintf "%-.15g" theta
                           |Deg -> sprintf "%-.15g" (180.0 /. pi *. theta)
                        in
                        let theta_len = String.length dummy_theta in
                        if theta_len > max_width.(m).(1) then
                           max_width.(m).(1) <- theta_len
                        else
                           ();
                  done
               done;
               (* now use the maximum field widths to align the columns
                * during string creation *)
               let initial_string = "[" in
               let line = ref initial_string in
               for n = 0 to rows - 1 do
                  line := !line ^ "[ ";
                  for m = 0 to cols - 2 do
                     match calc_modes.complex with
                     |Rect ->
                        line := !line ^ (sprintf "(%*.15g, %*.15g), " 
                           max_width.(m).(0) cm.{n, m}.Complex.re 
                           max_width.(m).(1) cm.{n, m}.Complex.im)
                     |Polar ->
                        begin
                           let rr = cm.{n, m}.Complex.re
                           and ii = cm.{n, m}.Complex.im in
                           let r = sqrt (rr *. rr +. ii *. ii)
                           and theta = atan2 ii rr in
                           match calc_modes.angle with
                           |Rad ->
                              line := !line ^ (sprintf "(%*.15g <%*.15g), " 
                              max_width.(m).(0) r max_width.(m).(1) theta)
                           |Deg ->
                              line := !line ^ (sprintf "(%*.15g <%*.15g), " 
                              max_width.(m).(0) r max_width.(m).(1) 
                              (180.0 /. pi *. theta))
                        end
                  done;
                  begin match calc_modes.complex with
                  |Rect ->
                     line := !line ^ (sprintf "(%*.15g, %*.15g) ]" 
                        max_width.(cols-1).(0) cm.{n, cols-1}.Complex.re 
                        max_width.(cols-1).(1) cm.{n, cols-1}.Complex.im)
                  |Polar ->
                     begin
                        let rr = cm.{n, cols-1}.Complex.re
                        and ii = cm.{n, cols-1}.Complex.im in
                        let r = sqrt (rr *. rr +. ii *. ii)
                        and theta = atan2 ii rr in
                        match calc_modes.angle with
                        |Rad ->
                           line := !line ^ (sprintf "(%*.15g <%*.15g) ]" 
                           max_width.(cols-1).(0) r max_width.(cols-1).(1) theta)
                        |Deg ->
                           line := !line ^ (sprintf "(%*.15g <%*.15g) ]" 
                           max_width.(cols-1).(0) r max_width.(cols-1).(1) 
                           (180.0 /. pi *. theta))
                     end
                  end;
                  if n < pred rows then
                     line := !line ^ "\n "
                  else
                     ()
               done;
               line := !line ^ "]";
               !line
            in
            let ss = append_units s in
            if !Rcfile.conserve_memory then 
               () 
            else
               begin match calc_modes.complex with
               |Rect ->
                  cm_str.cmat_rect_fs <- Some ss;
               |Polar ->
                  begin match calc_modes.angle with
                  |Rad -> cm_str.cmat_pol_rad_fs <- Some ss
                  |Deg -> cm_str.cmat_pol_deg_fs <- Some ss
                  end
               end;
            ss



      (* generate a string representation for a complex matrix,
       * taking into account the display mode. *)
      method private create_var_string disp_mode vv vv_str =
         let line = "@ " ^ vv
         and fs   = "@" ^ vv in
         if !Rcfile.conserve_memory then 
            () 
         else begin
            vv_str.v_line <- Some line;
            vv_str.v_fs   <- Some fs
         end;
         match disp_mode with
         |Line       -> line
         |Fullscreen -> fs


      method launch_fill_in_thread () =
         let _ = Thread.create self#fill_in_all_strings () in ()


      (* fill in any unknown string representations from the stack *)
      method private fill_in_all_strings () =
         try
            while true do
               let unrendered_el = Stack.pop render_stack in
               self#render_all_strings unrendered_el
            done
         with
            Stack.Empty -> ()

end


(* arch-tag: DO_NOT_CHANGE_59b80e87-dfde-4203-a7a2-8e1f95813151 *)
