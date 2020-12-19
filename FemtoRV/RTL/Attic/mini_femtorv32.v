// femtorv32, a minimalistic RISC-V RV32I core 
//   (minus SYSTEM and FENCE that are not implemented)
// Bruno Levy, May-June 2020
//
// drop-in replacement of femtorv32, 
// does 3 CPIs (cycles per instructions) in linear execution flow
// (two be compared with 2 CPIs with femtorv32.v),
// saves 20-50 LUTs
// in femtosoc.v, replace  `include "femtorv32.v"     
//                 with    `include "mini_femtorv32.v"
//
// NOTE: the structure of the decoder has changed, *** NEEDS TO BE ADAPTED ***


/*******************************************************************/

`include "utils.v"                 // Utilities, macros for debugging
`include "register_file.v"         // The 31 general-purpose registers
`include "small_alu.v"             // Used on IceStick, RV32I   
`include "large_alu.v"             // For larger FPGAs, RV32IM
`include "branch_predicates.v"     // Tests for branch instructions
`include "decoder.v"               // The instruction decoder
`include "aligned_memory_access.v" // Read/write bytes, hwords and words from memory
`include "CSR_file.v"              // (Optional) Control and Status registers 

/********************* Nrv processor *******************************/

module FemtoRV32 #(
  parameter [0:0] RV32M              = 0, // Set to 1 to support mul/div/rem instructions		   
  parameter       ADDR_WIDTH         = 16 // width of the address bus
) (
   input 	     clk,

   // Memory interface: using the same protocol as Claire Wolf's picoR32
   //                   (WIP: add mem_valid / mem_ready protocol)
   output [31:0]      mem_addr,  // address bus, only ADDR_WIDTH bits are used
   output wire [31:0] mem_wdata, // data to be written
   output wire [3:0]  mem_wmask, // write mask for individual bytes (1 means write byte)   
   input [31:0]       mem_rdata, // input lines for both data and instr
   output wire 	      mem_rstrb, // active to initiate memory read
   input wire 	      mem_rbusy, // asserted if memory is busy reading value
   input wire         mem_wbusy, // asserted if memory is busy writing value
   
   input wire 	     reset, // set to 0 to reset the processor
   output wire 	     error  // 1 if current instruction could not be decoded
);


   // The internal register that stores the current address,
   // directly wired to the address bus.
   reg [ADDR_WIDTH-1:0] addressReg;

   // The program counter (not storing the two LSBs, always aligned)
   reg [ADDR_WIDTH-3:0] PC;

   assign mem_addr = addressReg;

   reg [31:0] instr;     // Latched instruction. 
   reg [31:0] nextInstr; // Prefetched instruction.

 
   // Next program counter in normal operation: advance one word
   // I do not use the ALU, I create an additional adder for that.
   // (not that the two LSBs are not stored, always aligned).
   wire [ADDR_WIDTH-3:0] PCplus4 = PC + 1;

   /**************************************************************************************************/
   // Instruction decoding.
   
   // Internal signals, all generated by the decoder from the current instruction.
   wire [4:0] 	 writeBackRegId; // The register to be written back
   wire 	 writeBackEn;    // Needs to be asserted for writing back
   wire [3:0]	 writeBackSel;   // 0001: ALU  0010: PC+4  0100: RAM  1000: CSR
   wire [4:0] 	 regId1;         // Register output 1
   wire [4:0] 	 regId2;         // Register output 2
   wire 	 aluInSel1;      // 0: register  1: pc
   wire 	 aluInSel2;      // 0: register  1: imm
   wire 	 aluSel;         // 0: force aluOp,aluQual to zero (ADD)  1: use aluOp,aluQual from instr field
   wire [2:0] 	 aluOp;          // one of the 8 operations done by the ALU
   wire 	 aluQual;        // 'qualifier' used by some operations (+/-, logical/arith shifts)
   wire          aluM;           // asserted if instr is RV32M.
   wire [31:0] 	 imm;            // immediate value decoded from the instruction
   wire          needWaitALU;    // asserted if instruction uses at least one additional phase in ALU
   wire 	 isLoad;         // guess what
   wire 	 isStore;        // guess what
   wire          isJump;         // guess what
   wire          isBranch;       // guess what
   wire          decoderError;   // true if instr does not correspond to any known instr

   // The instruction decoder, that reads the current instruction 
   // and generates all the signals from it. It is in fact just a
   // big combinatorial function.
   NrvDecoder decoder(
     .instr(instr),		     
     .writeBackRegId(writeBackRegId),
     .writeBackEn(writeBackEn),
     .writeBackSel(writeBackSel),
     .inRegId1(regId1),
     .inRegId2(regId2),
     .aluInSel1(aluInSel1), 
     .aluInSel2(aluInSel2),
     .aluSel(aluSel),		     
     .aluOp(aluOp),
     .aluQual(aluQual),
     .aluM(aluM),		      
     .needWaitALU(needWaitALU),		      
     .isLoad(isLoad),
     .isStore(isStore),
     .isJump(isJump),
     .isBranch(isBranch),
     .imm(imm),
     .error(decoderError)     		     
   );

   /**************************************************************************************************/   
   // Maybe not necessary, but I'd rather latch this one,
   // if this one glitches, then it will break everything...
   reg error_latched;
   assign error = error_latched;

   /**************************************************************************************************/      
   // The register file. At each cycle, it can read two
   // registers (available at next cycle) and write one.
   wire writeBack;

   reg  [31:0] writeBackData;
   wire [31:0] regOut1;
   wire [31:0] regOut2;   
   NrvRegisterFile regs(
    .clk(clk),
    .in(writeBackData),
    .inEn(writeBack),
    .inRegId(writeBackRegId),		       
    .outRegId1(regId1),
    .outRegId2(regId2),
    .out1(regOut1),
    .out2(regOut2) 
   );

   /**************************************************************************************************/         
   // The ALU, partly combinatorial, partly state (for shifts).
   wire [31:0] aluOut;
   wire        aluBusy;
   wire        alu_wenable;
   wire [31:0] aluIn1 = aluInSel1 ? {PC, 2'b00} : regOut1;
   wire [31:0] aluIn2 = aluInSel2 ? imm : regOut2;

   // Select the ALU based on RV32M (use large ALU) or plain RV32I (use small ALU)
   generate
      if(RV32M) begin
         NrvLargeALU alu(
            .clk(clk),	      
            .in1(aluIn1),
            .in2(aluIn2),
            .op(aluOp & {3{aluSel}}),
            .opqual(aluQual & aluSel),
            .opM(aluM),	 
            .out(aluOut),
            .wr(alu_wenable), 
            .busy(aluBusy)	      
         );
      end else begin 
         NrvSmallALU #(
`ifdef NRV_TWOSTAGE_SHIFTER	      
          .TWOSTAGE_SHIFTER(1)
`else
          .TWOSTAGE_SHIFTER(0)	      
`endif
         ) alu(
            .clk(clk),	      
            .in1(aluIn1),
            .in2(aluIn2),
            .op(aluOp & {3{aluSel}}),
            .opqual(aluQual & aluSel),
            .out(aluOut),
            .wr(alu_wenable), 
            .busy(aluBusy)	      
         );
      end
   endgenerate
   
   /****************************************************************************/

   // Memory only does 32-bit aligned accesses. Internally we have two small
   // circuits (one for LOAD and one for STORE) that shift and adapt data
   // according to data type (byte, halfword, word) and memory alignment (addr[1:0]).
   // In addition, it does sign-expansion (when loading a signed byte to a word for
   // instance).
   
   // LOAD: a small combinatorial circuit that realigns 
   // and sign-expands mem_rdata based 
   // on width (aluOp[1:0]), signed/unsigned flag (aluOp[2])
   // and the two LSBs of the address. 
   wire [31:0] LOAD_mem_rdata_aligned;
   NrvLoadFromMemory load_from_mem(
       .mem_rdata(mem_rdata),        // Raw data read from mem
       .addr_LSBs(mem_addr[1:0]),    // The two LSBs of the address
       .width(aluOp[1:0]),           // Data width: 00:byte 01:hword 10:word
       .is_unsigned(aluOp[2]),       // signed/unsigned flag
       .data(LOAD_mem_rdata_aligned) // Data ready to be sent to register				   
   );

   // STORE: a small combinatorial circuit that realigns
   // data to be written based on width and the two LSBs
   // of the address.
   // When a STORE instruction is executed, the data to be stored to
   // mem is available from the second register (regOut2) and the
   // address where to store it is the output of the ALU (aluOut).
   wire mem_wenable;   
   NrvStoreToMemory store_to_mem(
       .data(regOut2),          // Data to be sent, out of register
       .addr_LSBs(aluOut[1:0]), // The two LSBs of the address 
       .width(aluOp[1:0]),      // Data width: 00:byte 01:hword 10:word
       .mem_wdata(mem_wdata),   // Shifted data to be sent to memory
       .mem_wmask(mem_wmask),   // Write mask for the 4 bytes
       .wr_enable(mem_wenable)  // Write enable ('anded' with write mask)
   );
   
   /*************************************************************************/
   // Control and status registers
   
`ifdef NRV_CSR
   wire [31:0] CSR_rdata;
   wire        instr_retired;
   NrvControlStatusRegisterFile CSR(
      .clk(clk),                         // for counting cycles
      .instr_cnt(instr_retired),         // for counting retired instructions
      .reset(reset),                     // reset all CSRs to default value
      .CSRid(instr[31:20]),              // CSR Id, extracted from instr				    
      .rdata(CSR_rdata)                  // Read CSR value
      // TODO: test for errors (.error)
   );
`endif   
   // Note: writing to CSRs not implemented yet

 
   /*************************************************************************/
   // The value written back to the register file.
   
   always @(*) begin
      (* parallel_case, full_case *)
      case(1'b1)
	writeBackSel[0]: writeBackData = aluOut;
	writeBackSel[1]: writeBackData = {PCplus4, 2'b00};
	writeBackSel[2]: writeBackData = LOAD_mem_rdata_aligned;
`ifdef NRV_CSR
	writeBackSel[3]: writeBackData = CSR_rdata;	
`endif
      endcase
   end

   /*************************************************************************/
   // The predicate for conditional branches.
   
   wire predOut;
   NrvPredicate pred(
    .in1(regOut1),
    .in2(regOut2),
    .op(aluOp),
    .out(predOut)		    
   );

   /*************************************************************************/
   // And, last but not least, the state machine.
   /*************************************************************************/

   // The states, using 1-hot encoding (reduces
   // both LUT count and critical path).
   
   localparam INITIAL              = 8'b00000000;   
   localparam WAIT_INSTR           = 8'b00000001;
   localparam FETCH_INSTR          = 8'b00000010;
   localparam USE_PREFETCHED_INSTR = 8'b00000100;
   localparam FETCH_REGS           = 8'b00001000;
   localparam EXECUTE              = 8'b00010000;
   localparam WAIT_ALU_OR_DATA     = 8'b00100000;
   localparam LOAD                 = 8'b01000000;
   localparam ERROR                = 8'b10000000;

   localparam WAIT_INSTR_bit           = 0;
   localparam FETCH_INSTR_bit          = 1;
   localparam USE_PREFETCHED_INSTR_bit = 2;
   localparam FETCH_REGS_bit           = 3;
   localparam EXECUTE_bit              = 4;
   localparam WAIT_ALU_OR_DATA_bit     = 5;
   localparam LOAD_bit                 = 6;   
   localparam ERROR_bit                = 7;
   
   reg [7:0] state = INITIAL;
   
   // the internal signals that are determined combinatorially from
   // state and other signals.
   
   // The internal signal that enables register write-back
   assign writeBack = (state[EXECUTE_bit] && writeBackEn) || state[WAIT_ALU_OR_DATA_bit];

   // The memory-read signal. It is only needed for IO, hence it is only enabled
   // right before the LOAD state. To allow execution from IO-mapped devices, it
   // will be necessary to also enable it before instruction fetch.
   assign mem_rstrb = (state[EXECUTE_bit] && isLoad);

   // NOTE: memory write are done during the USE_PREFETCHED_INSTR state,
   // Can't be done during EXECUTE (would be better), because mem_addr
   // (needed) is updated at the end of EXECUTE.
   // See also how load_from_mem and store_to_mem are wired.
   assign mem_wenable = (state[USE_PREFETCHED_INSTR_bit] && isStore);

   // alu_wenable starts computation in the ALU (for functions that
   // require several cycles).
   assign alu_wenable = (state[EXECUTE_bit]);

   // instr_retired is asserted during one cycle for each
   // retired instructions. It is used to update the instruction
   // counter 'instret' in the control and status registers
`ifdef NRV_CSR   
   assign instr_retired = state[FETCH_REGS_bit];
`endif
   
   // And now the state machine

`define show_state(state) `verbose($display("    %s",state))
   
   always @(posedge clk) begin
      if(!reset) begin	
	 state <= INITIAL;
	 addressReg <= 0;
	 PC <= 0;
      end else
      case(1'b1)
	(state == 0): begin
	   `show_state("initial");
	   state <= WAIT_INSTR;
	end
	state[WAIT_INSTR_bit]: begin
	   `show_state("wait_instr");
	   // this state to give enough time to fetch the 
	   // instruction. Used for jumps and taken branches (and 
	   // when fetching the first instruction). 
	   state <= FETCH_INSTR;
	end
	state[FETCH_INSTR_bit]: begin
	   `show_state("fetch_instr");	   
	   instr <= mem_rdata;
	   // update instr address so that next instr is fetched during
	   // decode (and ready if there was no jump or branch)
	   addressReg <= {PCplus4, 2'b00};
	   state <= FETCH_REGS;
	end
	state[USE_PREFETCHED_INSTR_bit]: begin
	   `show_state("use_prefetched_instr");	   	   
	   // for linear execution flow, the prefetched isntr (nextInstr)
	   // can be used.
	   instr <= nextInstr;
	   // update instr address so that next instr is fetched during
	   // decode (and ready if there was no jump or branch)
	   addressReg <= {PCplus4, 2'b00};
	   // In addition, STORE instructions write to memory here.
	   // (see NrvStoreToMemory store_to_mem at beginning of file).
	   state <= FETCH_REGS;
	end
	state[FETCH_REGS_bit]: begin
	   `show_state("fetch_regs");	   	   	   
	   // instr was just updated -> input register ids also
	   // input registers available at next cycle 
	   state <= EXECUTE;
	   error_latched <= decoderError;
	end
	state[EXECUTE_bit]: begin
	   `show_state("execute");
	   
	   // input registers are read, aluOut is up to date
	   
	   // Looked-ahead instr.
	   nextInstr <= mem_rdata;
	   
	   // Needed for LOAD,STORE,jump,branch
	   // (in other cases it will be ignored)
	   addressReg <= aluOut; 
	   
	   if(error_latched) begin
	      state <= ERROR;
	   end else if(isLoad) begin
	      state <= LOAD;
	      PC <= PCplus4;
	   end else begin 
	      (* parallel_case, full_case *)
	      case(1'b1)
		isJump: begin 
		   PC <= aluOut[31:2];
		   state <= WAIT_INSTR;
		end
		isBranch: begin 
		   if(predOut) begin
		      PC <= aluOut[31:2];
		      state <= WAIT_INSTR;
		   end else begin
		      PC <= PCplus4;
		      state <= USE_PREFETCHED_INSTR;
		   end
		end
		default: begin // linear execution flow
		   PC <= PCplus4;
		   state <= needWaitALU ? WAIT_ALU_OR_DATA : USE_PREFETCHED_INSTR;
		end		   
	      endcase 
	   end 
	end
	state[LOAD_bit]: begin
	   `show_state("load");	   
	   // data address (aluOut) was just updated
	   // data ready at next cycle
	   // we go to WAIT_ALU_OR_DATA to write back read data
	   state <= WAIT_ALU_OR_DATA;
	end
	state[WAIT_ALU_OR_DATA_bit]: begin
	   `show_state("wait_alu_or_data");	   
	   // - If ALU is still busy, continue to wait.
	   // - register writeback is active
	   state <= aluBusy ? WAIT_ALU_OR_DATA : USE_PREFETCHED_INSTR;
	end
	state[ERROR_bit]: begin
	   `bench($display("ERROR"));	   	   	   
           state <= ERROR;
	end
	default: begin
	   `bench($display("UNKNOWN STATE"));	   	   	   
	   state <= ERROR;
	end
      endcase
  end   

/*********************************************************************/

`define show_opcode(opcode) `verbose($display("%x: %s",{PC,2'b00},opcode))
   
`ifdef BENCH
   always @(posedge clk) begin
      if(state[FETCH_REGS_bit]) begin
	 case(instr[6:0])
	   7'b0110111: `show_opcode("LUI");
	   7'b0010111: `show_opcode("AUIPC");
	   7'b1101111: `show_opcode("JAL");
	   7'b1100111: `show_opcode("JALR");
	   7'b1100011: `show_opcode("BRANCH");
	   7'b0010011: `show_opcode("ALU reg imm");
	   7'b0110011: `show_opcode("ALU reg reg");
	   7'b0000011: `show_opcode("LOAD");
	   7'b0100011: `show_opcode("STORE");
	   7'b0001111: `show_opcode("FENCE");
	   7'b1110011: `show_opcode("SYSTEM");
	 endcase // case (instr[6:0])
      end // if (state[EXECUTE_bit])
   end
`endif
   
endmodule