// Shared self-check macros. Each tb declares `integer errors = 0;`.
// CHECK uses !== so an X/Z result counts as a failure, not a silent pass.
`define CHECK(cond, msg) \
    if ((cond) !== 1'b1) begin errors = errors + 1; $display("  FAIL @%0t: %s", $time, msg); end
`define REPORT(name) \
    if (errors == 0) $display("RESULT %s: PASS", name); \
    else             $display("RESULT %s: FAIL (%0d errors)", name, errors);
