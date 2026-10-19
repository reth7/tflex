// =============================================================================
// tflex_sb_mux -- fixed-priority arbiter of sideband message requests onto the
// sideband channel (one message per cycle, docs/protocol.md section 6).
// Port 0 has the highest priority. Milestone 2 instantiates NAK > ACK > CREDIT;
// the LTSM's training messages take port 0 in Milestone 4.
// Requests are valid/ready streams; the sideband channel accepts every cycle,
// so a request is granted in the cycle it is the highest-priority one present.
// =============================================================================
module tflex_sb_mux
  import tflex_pkg::*;
#(
  parameter int N = 3
) (
  input  logic              [N-1:0] req_valid,
  output logic              [N-1:0] req_ready,
  input  sb_msg_t           [N-1:0] req_msg,
  output logic                      out_valid,
  output sb_msg_t                   out_msg
);
  always_comb begin
    req_ready = '0;
    out_valid = 1'b0;
    out_msg   = '0;
    for (int i = N - 1; i >= 0; i--) begin
      if (req_valid[i]) begin
        req_ready = '0;
        req_ready[i] = 1'b1;
        out_valid = 1'b1;
        out_msg   = req_msg[i];
      end
    end
  end
endmodule
