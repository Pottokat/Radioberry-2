//
//  HPSDR - High Performance Software Defined Radio
//
//  Hermes code. 
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 2 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program; if not, write to the Free Software
//  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

// Based on code  by James Ahlstrom, N2ADR,  (C) 2011
// Modified for use with HPSDR by Phil Harman, VK6PH, (C) 2013



// Interpolate by 8 Polyphase FIR filter.
// Produce an output when calc is strobed true.  Output a strobe on req
// to request a new input sample.
// Input sample bits are 16 bits wide.


/*

	Interpolate by 8 Polyphase filter.
	
	The classic method of increasing the sampling rate of a system is to insert zeros between input samples.
	In the case of interpolating by 8 the input data would look as follows:
	
	X0,0,0,0,0,0,0,0,X1,0,0,0,0,0,0,0,X2....
	
	Where Xn represents an input sample. The effect of adding the zero samples is to cause the output to 
	contain images centered on multiples of the original sample rate.  So, we must also 
	filter this result down to the original bandwidth.  Once we have done this, we have a signal at the
	higher sample rate that only has frequency content within the original bandwidth.
	
	Note that when we multiply the coefficients by the zero samples, they make zero contribution to the result.
	Only the actual input samples, when multiplied by coefficients, contribute to the result. In which case these 
	are the only input samples that we need to process.
	Let's call the coefficients C0, C1, C2, C3, ....  So, when we enter an actual input sample, 
	the input samples (spaced 8 apart) get multiplied by C0, C8, C16, C24, ... to generate the first result ... 
	everything else is just zero.  When we enter the next data sample, the existing input samples have shifted and
	the non-zero results are generated by C1, C9, C17 ..... and so on.


	
	
	The format of the Polyphase filter is as follows:
	
	Input	
				+----+----+-----+ ........+
		---|->| C0 | C8 | C16 | ........|----0  <------ Output
			|	+----+----+-----+ ........+
			|
			|	+----+----+-----+ ........+
			|->| C1 | C9 | C17 | ........|----0
			|	+----+----+-----+ ........+
			|	
			|	+----+----+-----+ ........+
			|->| C2 | C10| C18 | ........|----0
			|	+----+----+-----+ ........+

			
						etc
			
							
			|	+----+----+-----+ ........+
			|->| C7 | C15| C23 | ........|----0
			|	+----+----+-----+ ........+


	Conceptually the filter operates as follows.  Each input sample at 48ksps is fed to each FIR. When an output sample is 
	requested the input samples are mutlipled by the coefficients the output is pointing to. Hence for 
	each input sample there are 8 outputs.

	As implemented, the input samples are stored in RAM. Each new sample is saved at the next RAM address.  When an output 
	value is requested (by strobing calc) the samples in RAM are multiplied by the coefficients held in ROM. After each sample and coefficient
	multiplication the RAM address is decremented and the ROM address incremented by 8.  This is repeated until all the samples 
	have been multiplied by a coefficient.
	
	Prior to the next request for an output value the ROM starting address is incremented by one. Hence for the first output
	coefficients C0, C8, C16.... are used, for the second output coefficients C1, C9, C18....are used etc.
	
	Once all 8 sets of coefficients have been processed a new input sample is requested. 
	


*/

module FirInterp8_1024(
	input clock,
	input calc,						// calculate an output sample
	output reg req,					// request the next input sample
	input signed [15:0] x_real,		// input samples
	input signed [15:0] x_imag,
	output reg signed [OBITS-1:0] y_real,	// output samples
	output reg signed [OBITS-1:0] y_imag
	);
	
	parameter OBITS			= 20;		// output bits
	parameter ABITS			= 24;		// adder bits
	parameter NTAPS			= 11'd1024;	// number of filter taps, even by 8, 1024-8 max
	parameter NTAPS_BITS		= 10;		// number of address bits for coefficient memory

	reg [3:0] rstate;		// state machine
	parameter rWait		= 0;
	parameter rAddr		= 1;
	parameter rAddrA		= 2;
	parameter rAddrB		= 3;
	parameter rRun			= 4;
	parameter rDone		= 5;
	parameter rEnd1		= 6;
	parameter rEnd2		= 7;
	parameter rEnd3		= 8;
	parameter rEnd4		= 9;

	// We need memory for NTAPS / 8 samples saved in memory
	reg  [6:0] waddr, raddr;			// write and read sample memory address
	reg  we;									// write enable for samples
	reg  signed [ABITS-1:0] Raccum, Iaccum;		// accumulators
	wire [35:0] q;							// I/Q sample read from memory
	reg  [35:0] reg_q;
	wire signed [17:0] q_real, q_imag;
	assign q_real = reg_q[35:18];
	assign q_imag = reg_q[17:0];
	reg  [NTAPS_BITS-1:0] caddr;		// read address for coefficient
	wire signed [17:0] coef;			// 18-bit coefficient read from memory
	reg  signed [17:0] reg_coef;
	reg  signed [35:0] Rmult, Imult;	// multiplier result
	reg  [2:0] phase;						// count 0, 1, ..., 7
	reg  [9:0] counter;					// count NTAPS/8 samples + latency


	initial
	begin
		rstate = rWait;
		waddr = 0;
		req = 0;
		phase = 0;
	end

//`ifdef USE_ALTSYNCRAM	
	firromI_1024 #(.init_file("coefI8_1024.mif")) rom (caddr, clock, coef);	// coefficient ROM 18 bits X NTAPS
//`else 
//	firromI_1024 #(.init_file("coefI8_1024.txt")) rom (caddr, clock, coef);	// coefficient ROM 18 bits X NTAPS
//`endif 
	// sample RAM 36 bits X 128;  36 bit == 18 bits I and 18 bits Q
	// sign extend the input samples; they remain at 16 bits
	wire [35:0] sx_input;
	assign sx_input = {x_real[15], x_real[15], x_real, x_imag[15], x_imag[15], x_imag};
	firram36I_1024 ram (clock, sx_input, raddr, waddr, we, q);

	task next_addr;		// increment address and register the next sample and coef
		raddr <= raddr - 1'd1;		// move to prior sample
		caddr <= caddr + 4'd8;		// move to next coefficient
		reg_q <= q;
		reg_coef <= coef;
	endtask

	always @(posedge clock)
	begin
		case (rstate)
			rWait:
			begin
				if (calc)	// Wait until a new result is requested
				begin
					rstate <= rAddr;
					raddr <= waddr;		// read address -> newest sample
					caddr <= phase;		// start coefficient
					counter <= NTAPS / 11'd8 + 1'd1;	// count samples and pipeline latency
					Raccum <= 1'd0;
					Iaccum <= 1'd0;
					Rmult <= 1'd0;
					Imult <= 1'd0;
				end
			end
			rAddr:	// prime the memory pipeline
			begin
				rstate <= rAddrA;
				next_addr;
			end
			rAddrA:
			begin
				rstate <= rAddrB;
				next_addr;
			end
			rAddrB:
			begin
				rstate <= rRun;
				next_addr;
			end
			rRun:
			begin		// main pipeline here
				next_addr;
				Rmult <= q_real * reg_coef;
				Imult <= q_imag * reg_coef;
				Raccum <= Raccum + Rmult[35:12] + Rmult[11];		// Add the most significant bits
				Iaccum <= Iaccum + Imult[35:12] + Imult[11];
				counter <= counter - 1'd1;
				if (counter == 0)
				begin
					rstate <= rDone;
				end
			end
			rDone:
			begin
				// Input samples were 16 bits in 18
				// Coefficients were multiplied by 8
				//y_real <= Raccum[(ABITS-1-3) -: OBITS];
				//y_imag <= Iaccum[(ABITS-1-3) -: OBITS];
				y_real <= Raccum[20:1] + Raccum[1];			// truncate to 20 bits to eliminate DC component
				y_imag <= Iaccum[20:1] + Iaccum[1];
				if (phase == 3'b111)
					rstate <= rEnd1;
				else
					rstate <= rWait;
				phase <= phase + 1'd1;
			end
			rEnd1:		// This was the last output sample for this input sample
			begin
				rstate <= rEnd2;
				waddr <= waddr + 1'd1;	// next write address
			end
			rEnd2:
			begin
				rstate <= rEnd3;
				we <= 1'd1;	// write current new sample at new address
			end
			rEnd3:
			begin
				rstate <= rEnd4;
				we <= 1'd0;
				req <= 1'd1;			// request next sample
			end
			rEnd4:
			begin
				rstate <= rWait;
				req <= 1'd0;
			end
		endcase
	end
endmodule
