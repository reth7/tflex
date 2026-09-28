// =============================================================================
// tflex_pkg.sv  --  T-FLEX shared types and parameters  (Phase 1 DRAFT)
//
// This package is the executable form of docs/protocol.md: flit and header
// layouts, sideband messages, link-training states and fault-injection modes.
// It is lint-clean under Verilator and converts through sv2v for Yosys.
//
// T-FLEX is a UCIe-inspired architectural/RTL research model and is not a
// certified implementation of the UCIe specification.
// =============================================================================
package tflex_pkg;

  // ---------------------------------------------------------------------------
  // Default parameters (every module takes these as overridable parameters;
  // values here only serve as defaults and must match configs/default.yaml)
  // ---------------------------------------------------------------------------
  localparam int DATA_LANES   = 32;   // logical lanes
  localparam int SPARE_LANES  = 4;    // redundant physical lanes
  localparam int PHYS_LANES   = DATA_LANES + SPARE_LANES;
  localparam int LANE_BITS    = 8;    // bits per lane per link-clock cycle
  localparam int FLIT_BITS    = 256;
  localparam int SEQ_BITS     = 8;
  localparam int CRC_BITS     = 16;
  localparam int CTRL_BITS    = 16;   // ftype + seq + flags
  localparam int BODY_BITS    = FLIT_BITS - CTRL_BITS - CRC_BITS;   // 224
  localparam int BODY_BYTES   = BODY_BITS / 8;                      // 28
  localparam int LANE_IDX_W   = $clog2(PHYS_LANES);                 // 6

  localparam logic [CRC_BITS-1:0] CRC_POLY = 16'h1021;  // CRC-16/CCITT, configurable
  localparam logic [CRC_BITS-1:0] CRC_INIT = 16'hFFFF;

  // ---------------------------------------------------------------------------
  // Flit (256 b). Bit 255 is the MSB and is transmitted in logical lane 31's
  // byte of beat 0 (see protocol.md, "Striping").
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    FT_IDLE      = 3'd0,   // no packet content; not sequenced, not retried
    FT_HEAD      = 3'd1,   // header flit of a multi-flit packet
    FT_DATA      = 3'd2,   // payload flit
    FT_TAIL      = 3'd3,   // last payload flit
    FT_HEAD_TAIL = 3'd4,   // single-flit packet (e.g. READ_REQ, WRITE_ACK)
    FT_RSVD5     = 3'd5,
    FT_RSVD6     = 3'd6,
    FT_RSVD7     = 3'd7
  } flit_type_e;

  typedef struct packed {
    logic       replay;    // set by the TX retry engine on retransmitted flits (stats only)
    logic [3:0] rsvd;
  } flit_flags_t;

  typedef struct packed {
    flit_type_e             ftype;   // [255:253]
    logic [SEQ_BITS-1:0]    seq;     // [252:245]
    flit_flags_t            flags;   // [244:240]
    logic [BODY_BITS-1:0]   body;    // [239:16]
    logic [CRC_BITS-1:0]    crc;     // [15:0]  covers bits [255:16]
  } flit_t;

  // ---------------------------------------------------------------------------
  // Packet header (carried in the body of FT_HEAD / FT_HEAD_TAIL flits)
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    NODE_AI   = 4'd0,
    NODE_SRAM = 4'd1,
    NODE_HBM  = 4'd2,
    NODE_BASE = 4'd3
  } node_id_e;

  typedef enum logic [3:0] {
    PT_WR_REQ  = 4'd0,     // carries payload
    PT_RD_REQ  = 4'd1,     // header only; `len` = bytes requested
    PT_RD_RESP = 4'd2,     // carries payload
    PT_WR_ACK  = 4'd3      // header only
  } pkt_type_e;

  typedef enum logic [3:0] {
    TC_GENERIC    = 4'd0,
    TC_WEIGHT     = 4'd1,
    TC_ACTIVATION = 4'd2,
    TC_KV_CACHE   = 4'd3,
    TC_PARTIAL    = 4'd4   // partial sums / outputs
  } traffic_class_e;

  typedef enum logic [1:0] {
    PATH_S = 2'd0,         // AI <-> SRAM
    PATH_A = 2'd1,         // AI <-> HBM, link A
    PATH_B = 2'd2          // AI <-> HBM, link B
  } path_id_e;

  typedef struct packed {
    node_id_e        src;         // 4
    node_id_e        dst;         // 4
    pkt_type_e       ptype;       // 4
    traffic_class_e  tclass;      // 4
    logic [1:0]      prio;        // 2   0 = lowest
    path_id_e        path;        // 2   path the packet was routed on (stats)
    logic [3:0]      rsvd0;       // 4
    logic [15:0]     len;         // 16  transfer length in bytes
    logic [15:0]     tag;         // 16  transaction tag (responses echo it)
    logic [47:0]     addr;        // 48
    logic [63:0]     inject_ts;   // 64  DEBUG: core-cycle injection time for latency stats
    logic [55:0]     rsvd1;       // 56
  } pkt_hdr_t;                    // = 224 bits

  // ---------------------------------------------------------------------------
  // Sideband messages (assumed reliable, fixed latency)
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    SB_NOP         = 4'd0,
    SB_DETECT_REQ  = 4'd1,
    SB_DETECT_ACK  = 4'd2,
    SB_TRAIN_START = 4'd3,   // arg: requested width mode + frequency level
    SB_LANE_RESULT = 4'd4,   // arg[35:0]: RX per-physical-lane pass mask
    SB_MAP_COMMIT  = 4'd5,   // arg: width mode + spare usage; both ends switch maps
    SB_DESKEW_DONE = 4'd6,
    SB_ACTIVE      = 4'd7,
    SB_ACK         = 4'd8,   // arg[7:0]: cumulative ACK up to seq
    SB_NAK         = 4'd9,   // arg[7:0]: expected seq (go-back-N from here)
    SB_CREDIT      = 4'd10,  // arg[7:0]: credits returned
    SB_RETRAIN_REQ = 4'd11,  // arg[3:0]: retrain_reason_e
    SB_RSVD12      = 4'd12,
    SB_RSVD13      = 4'd13,
    SB_RSVD14      = 4'd14,
    SB_RSVD15      = 4'd15
  } sb_opcode_e;

  typedef struct packed {
    sb_opcode_e  op;
    logic [39:0] arg;
  } sb_msg_t;

  typedef enum logic [3:0] {
    RR_NONE      = 4'd0,
    RR_CRC_BURST = 4'd1,     // retries exhausted or NAK storm
    RR_WIDTH_CHG = 4'd2,     // thermal controller / degraded width
    RR_FREQ_CHG  = 4'd3,     // thermal controller frequency step
    RR_LINK_LOST = 4'd4,     // training pattern lost on all lanes
    RR_HOST_REQ  = 4'd5      // CSR-initiated
  } retrain_reason_e;

  // ---------------------------------------------------------------------------
  // Link training state machine
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    LT_RESET      = 4'd0,
    LT_DETECT     = 4'd1,
    LT_TRAIN      = 4'd2,    // PRBS on all physical lanes
    LT_LANE_CHECK = 4'd3,    // per-lane compare, exchange pass masks
    LT_REPAIR     = 4'd4,    // compute lane map / width, commit on both ends
    LT_DESKEW     = 4'd5,
    LT_ACTIVE     = 4'd6,
    LT_ERROR      = 4'd7,
    LT_RETRAIN    = 4'd8,    // quiesce, drain, then re-enter TRAIN
    LT_LINK_DOWN  = 4'd9     // fewer than min_width good lanes
  } ltsm_state_e;

  typedef enum logic [1:0] {
    WM_32 = 2'd0,
    WM_24 = 2'd1,
    WM_16 = 2'd2,
    WM_8  = 2'd3
  } width_mode_e;

  function automatic int unsigned width_lanes(width_mode_e wm);
    case (wm)
      WM_32:   return 32;
      WM_24:   return 24;
      WM_16:   return 16;
      default: return 8;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Fault injection
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    FM_NONE         = 4'd0,
    FM_BIT_FLIP     = 4'd1,  // one bit, one cycle
    FM_BURST        = 4'd2,  // all bits of lane_mask for `duration` cycles
    FM_STUCK0       = 4'd3,
    FM_STUCK1       = 4'd4,
    FM_LANE_DEAD    = 4'd5,  // lane output replaced by LFSR noise (permanent)
    FM_PKT_CORRUPT  = 4'd6,  // flip body bits of the next non-idle flit
    FM_CRC_CORRUPT  = 4'd7,  // flip CRC bits of the next non-idle flit
    FM_LINK_DOWN    = 4'd8,  // every lane noisy for `duration` cycles (temporary)
    FM_RANDOM_BER   = 4'd9   // Bernoulli bit errors, p = ber_thresh / 2^32
  } fault_mode_e;

  typedef struct packed {
    fault_mode_e            mode;
    logic [PHYS_LANES-1:0]  lane_mask;
    logic [2:0]             bit_idx;     // FM_BIT_FLIP
    logic [31:0]            start_cycle; // link-clock cycle, absolute
    logic [23:0]            duration;    // 0 = permanent (where meaningful)
    logic [31:0]            ber_thresh;  // FM_RANDOM_BER
  } fault_cmd_t;

endpackage : tflex_pkg
