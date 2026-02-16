const std = @import("std");
const wasm = @import("wasm");

const Context = @import("Context.zig");

const io = std.io;
const types = wasm.types;
const instr = wasm.instr;

const Allocator = std.mem.Allocator;
const ValType = types.ValType;
const Instruction = instr.Instruction;
const Opcode = instr.Opcode;

const ControlFrame = struct {
    opcode: Opcode = undefined,
    result: ?ValType,
    height: usize = 0,
};

pub const State = struct {
    stack: std.ArrayList(ValType) = .{},
    ctrl_stack: std.ArrayList(ControlFrame) = .{},
    reachable: bool = true,

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.stack.deinit(allocator);
        self.ctrl_stack.deinit(allocator);
    }

    pub fn push(self: *State, allocator: Allocator, ty: ValType) !void {
        try self.stack.append(allocator, ty);
    }

    fn pushSlice(self: *State, allocator: Allocator, operands: []const ValType) !void {
        for (operands) |op| try self.push(allocator, op);
    }

    pub fn pop(self: *State) !ValType {
        if (self.stack.items.len == 0) return error.OperandStackUnderflow;
        return self.stack.pop().?;
    }

    fn popExpect(self: *State, expected: ValType) !ValType {
        const ty = try self.pop();
        if (ty != expected) return error.TypeMismatch;
        return ty;
    }

    fn popSliceExpect(self: *State, expected: []const ValType) !void {
        const len = expected.len;
        for (expected, 0..) |_, i| _ = try self.popExpect(expected[len - i - 1]);
    }

    pub fn pushFrame(self: *State, allocator: Allocator, opcode: Opcode, res: ?ValType) !void {
        const frame = ControlFrame{
            .opcode = opcode,
            .result = res,
            .height = self.stack.items.len,
        };
        try self.ctrl_stack.append(allocator, frame);
    }

    fn popFrame(self: *State) !ControlFrame {
        if (self.ctrl_stack.items.len == 0) return error.ControlStackUnderflow;
        const frame = self.ctrl_stack.pop().?;
        if (frame.result) |res| _ = try self.popExpect(res);

        if (self.stack.items.len != frame.height) return error.ControlFrameMismatchedSizes;
        return frame;
    }
};

pub fn validateCode(ctx: *Context, body: types.FuncBody, func_idx: u32) !void {
    const allocator = ctx.allocator;
    const func_type = ctx.typeOfFunc(ctx.imported_funcs + func_idx);

    const locals = try body.collectLocals(ctx.allocator);
    defer ctx.allocator.free(locals);

    var state = State{};
    defer state.deinit(allocator);

    const func_res = if (func_type.results.len != 0) func_type.results[0] else null;
    try state.pushFrame(allocator, .block, func_res);

    var has_returned = false;

    var it = instr.Iterator.init(body.code);

    while (try it.next()) |in| {
        if (!state.reachable and in != .end and in != .@"else") continue;

        switch (in) {
            // CONTROL
            .@"unreachable" => state.reachable = false,
            .nop => {},

            inline .block, .loop => |block_type, tag| {
                const res = if (block_type == .valtype) block_type.valtype else null;
                try state.pushFrame(allocator, tag, res);
            },

            .@"if" => |block_type| {
                _ = try state.popExpect(.i32);
                const res = if (block_type == .valtype) block_type.valtype else null;
                try state.pushFrame(allocator, .@"if", res);
            },

            .@"else" => {
                const frame = state.ctrl_stack.getLast();
                if (frame.opcode != .@"if") return error.ElseMustOnlyOccurAfterIf;
            },

            .end => {
                const frame = state.ctrl_stack.pop().?;

                if (state.ctrl_stack.items.len == 0) {
                    if (has_returned) {
                        if (state.stack.items.len != 0) return error.TypeMismatchAfterExplicitReturn;
                    } else {
                        if (frame.result) |result_type| _ = try state.popExpect(result_type);
                        if (state.stack.items.len != 0) return error.TypeMismatchAtFunctionEnd;
                    }
                } else {
                    if (frame.result) |result_type| {
                        _ = try state.popExpect(result_type);
                        try state.push(allocator, result_type);
                    }
                    state.reachable = true;
                }
            },

            .br => |label| {
                if (label >= state.ctrl_stack.items.len) return error.ValidateBrInvalidLabel;
                const frame = state.ctrl_stack.items[state.ctrl_stack.items.len - 1 - label];

                if (frame.result) |res| _ = try state.popExpect(res);
                state.reachable = false;
            },

            .br_if => |label| {
                if (label >= state.ctrl_stack.items.len) return error.ValidateBrIfInvalidLabel;
                const frame = state.ctrl_stack.items[state.ctrl_stack.items.len - 1 - label];

                _ = try state.popExpect(.i32);
                if (frame.result) |res| {
                    _ = try state.popExpect(res);
                    try state.push(allocator, res);
                }
            },
            .br_table => |_| unreachable,

            .@"return" => {
                const func_frame = state.ctrl_stack.items[0];

                if (func_frame.result) |res| _ = try state.popExpect(res);
                state.reachable = false;
                has_returned = true;
            },

            .call => |idx| {
                const callee_type = ctx.typeOfFunc(idx);
                _ = try state.popSliceExpect(callee_type.params);

                if (callee_type.results.len > 0) {
                    try state.push(allocator, callee_type.results[0]);
                }
            },

            .call_indirect => |call| {
                _ = try state.popExpect(.i32);
                const callee_type = ctx.functypes.items[call.type_idx];

                _ = try state.popSliceExpect(callee_type.params);
                if (callee_type.results.len > 0) {
                    try state.push(allocator, callee_type.results[0]);
                }
            },

            // PARAMETRIC
            .drop => _ = try state.pop(),
            .select => {
                _ = try state.popExpect(.i32);
                const t2 = try state.pop();
                const t1 = try state.pop();

                if (t1 != t2) return error.SelectTypeMismatch;
                try state.push(allocator, t1);
            },

            // VARIABLES
            .@"local.get" => |idx| {
                if (idx < func_type.params.len) {
                    try state.push(allocator, func_type.params[idx]);
                    continue;
                }
                const local = locals[idx - func_type.params.len];
                try state.push(allocator, local);
            },
            .@"local.set" => |idx| {
                if (idx < func_type.params.len) {
                    _ = try state.popExpect(func_type.params[idx]);
                    continue;
                }
                const local = locals[idx - func_type.params.len];
                _ = try state.popExpect(local);
            },
            .@"local.tee" => |idx| {
                if (idx < func_type.params.len) {
                    _ = try state.popExpect(func_type.params[idx]);
                    try state.push(allocator, func_type.params[idx]);
                    continue;
                }
                const local = locals[idx - func_type.params.len];
                _ = try state.popExpect(local);
                try state.push(allocator, local);
            },
            .@"global.get" => |idx| {
                const global_type = ctx.globals.items[idx];
                try state.push(allocator, global_type.valtype);
            },
            .@"global.set" => |idx| {
                const global_type = ctx.globals.items[idx];
                _ = try state.popExpect(global_type.valtype);
            },

            // MEMORY LOAD
            .@"i32.load",
            .@"i32.load8_s",
            .@"i32.load8_u",
            .@"i32.load16_s",
            .@"i32.load16_u",
            => try validateUnaryOp(allocator, &state, .i32, .i32),

            .@"i64.load",
            .@"i64.load8_s",
            .@"i64.load8_u",
            .@"i64.load16_s",
            .@"i64.load16_u",
            .@"i64.load32_s",
            .@"i64.load32_u",
            => try validateUnaryOp(allocator, &state, .i32, .i64),

            .@"f32.load" => try validateUnaryOp(allocator, &state, .i32, .f32),
            .@"f64.load" => try validateUnaryOp(allocator, &state, .i32, .f64),

            // MEMORY STORE
            .@"i32.store",
            .@"i32.store8",
            .@"i32.store16",
            => {
                _ = try state.popExpect(.i32);
                _ = try state.popExpect(.i32);
            },

            .@"i64.store",
            .@"i64.store8",
            .@"i64.store16",
            .@"i64.store32",
            => {
                _ = try state.popExpect(.i64);
                _ = try state.popExpect(.i32);
            },
            .@"f32.store" => {
                _ = try state.popExpect(.f32);
                _ = try state.popExpect(.i32);
            },
            .@"f64.store" => {
                _ = try state.popExpect(.f64);
                _ = try state.popExpect(.i32);
            },

            // MEMORY SIZE / GROW
            .@"memory.size" => try state.push(allocator, .i32),
            .@"memory.grow" => try validateUnaryOp(allocator, &state, .i32, .i32),

            // CONSTANTS
            .@"i32.const" => try state.push(allocator, .i32),
            .@"i64.const" => try state.push(allocator, .i64),
            .@"f32.const" => try state.push(allocator, .f32),
            .@"f64.const" => try state.push(allocator, .f64),

            // NUMERIC OPS
            .@"i32.eqz" => try validateUnaryOp(allocator, &state, .i32, .i32),
            .@"i64.eqz" => try validateUnaryOp(allocator, &state, .i64, .i32),

            .@"i32.eq",
            .@"i32.ne",
            .@"i32.lt_s",
            .@"i32.lt_u",
            .@"i32.gt_s",
            .@"i32.gt_u",
            .@"i32.le_s",
            .@"i32.le_u",
            .@"i32.ge_s",
            .@"i32.ge_u",
            => try validateBinaryOp(allocator, &state, .i32, .i32, .i32),

            .@"i64.eq",
            .@"i64.ne",
            .@"i64.lt_s",
            .@"i64.lt_u",
            .@"i64.gt_s",
            .@"i64.gt_u",
            .@"i64.le_s",
            .@"i64.le_u",
            .@"i64.ge_s",
            .@"i64.ge_u",
            => try validateBinaryOp(allocator, &state, .i64, .i64, .i32),

            .@"f32.eq",
            .@"f32.ne",
            .@"f32.lt",
            .@"f32.gt",
            .@"f32.le",
            .@"f32.ge",
            => try validateBinaryOp(allocator, &state, .f32, .f32, .i32),

            .@"f64.eq",
            .@"f64.ne",
            .@"f64.lt",
            .@"f64.gt",
            .@"f64.le",
            .@"f64.ge",
            => try validateBinaryOp(allocator, &state, .f64, .f64, .i32),

            .@"i32.clz",
            .@"i32.ctz",
            .@"i32.popcnt",
            => try validateUnaryOp(allocator, &state, .i32, .i32),

            .@"i64.clz",
            .@"i64.ctz",
            .@"i64.popcnt",
            => try validateUnaryOp(allocator, &state, .i64, .i64),

            .@"f32.abs",
            .@"f32.neg",
            .@"f32.ceil",
            .@"f32.floor",
            .@"f32.trunc",
            .@"f32.nearest",
            .@"f32.sqrt",
            => try validateUnaryOp(allocator, &state, .f32, .f32),

            .@"f64.abs",
            .@"f64.neg",
            .@"f64.ceil",
            .@"f64.floor",
            .@"f64.trunc",
            .@"f64.nearest",
            .@"f64.sqrt",
            => try validateUnaryOp(allocator, &state, .f64, .f64),

            .@"i32.add",
            .@"i32.sub",
            .@"i32.mul",
            .@"i32.div_s",
            .@"i32.div_u",
            .@"i32.rem_s",
            .@"i32.rem_u",
            .@"i32.and",
            .@"i32.or",
            .@"i32.xor",
            .@"i32.shl",
            .@"i32.shr_s",
            .@"i32.shr_u",
            .@"i32.rotl",
            .@"i32.rotr",
            => try validateBinaryOp(allocator, &state, .i32, .i32, .i32),

            .@"i64.add",
            .@"i64.sub",
            .@"i64.mul",
            .@"i64.div_s",
            .@"i64.div_u",
            .@"i64.rem_s",
            .@"i64.rem_u",
            .@"i64.and",
            .@"i64.or",
            .@"i64.xor",
            .@"i64.shl",
            .@"i64.shr_s",
            .@"i64.shr_u",
            .@"i64.rotl",
            .@"i64.rotr",
            => try validateBinaryOp(allocator, &state, .i64, .i64, .i64),

            .@"f32.add",
            .@"f32.sub",
            .@"f32.mul",
            .@"f32.div",
            .@"f32.min",
            .@"f32.max",
            .@"f32.copysign",
            => try validateBinaryOp(allocator, &state, .f32, .f32, .f32),

            .@"f64.add",
            .@"f64.sub",
            .@"f64.mul",
            .@"f64.div",
            .@"f64.min",
            .@"f64.max",
            .@"f64.copysign",
            => try validateBinaryOp(allocator, &state, .f64, .f64, .f64),

            // CONVERSIONS
            .@"i32.wrap_i64" => try validateUnaryOp(allocator, &state, .i64, .i32),

            .@"i32.trunc_f32_s",
            .@"i32.trunc_f32_u",
            => try validateUnaryOp(allocator, &state, .f32, .i32),

            .@"i32.trunc_f64_s",
            .@"i32.trunc_f64_u",
            => try validateUnaryOp(allocator, &state, .f64, .i32),

            .@"i64.extend_i32_s",
            .@"i64.extend_i32_u",
            => try validateUnaryOp(allocator, &state, .i32, .i64),

            .@"i64.trunc_f32_s",
            .@"i64.trunc_f32_u",
            => try validateUnaryOp(allocator, &state, .f32, .i64),

            .@"i64.trunc_f64_s",
            .@"i64.trunc_f64_u",
            => try validateUnaryOp(allocator, &state, .f64, .i64),

            .@"f32.convert_i32_s",
            .@"f32.convert_i32_u",
            => try validateUnaryOp(allocator, &state, .i32, .f32),

            .@"f32.convert_i64_s",
            .@"f32.convert_i64_u",
            => try validateUnaryOp(allocator, &state, .i64, .f32),

            .@"f32.demote_f64" => try validateUnaryOp(allocator, &state, .f64, .f32),

            .@"f64.convert_i32_s",
            .@"f64.convert_i32_u",
            => try validateUnaryOp(allocator, &state, .i32, .f64),

            .@"f64.convert_i64_s",
            .@"f64.convert_i64_u",
            => try validateUnaryOp(allocator, &state, .i64, .f64),

            .@"f64.promote_f32" => try validateUnaryOp(allocator, &state, .f32, .f64),

            .@"i32.reinterpret_f32" => try validateUnaryOp(allocator, &state, .f32, .i32),
            .@"i64.reinterpret_f64" => try validateUnaryOp(allocator, &state, .f64, .i64),
            .@"f32.reinterpret_i32" => try validateUnaryOp(allocator, &state, .i32, .f32),
            .@"f64.reinterpret_i64" => try validateUnaryOp(allocator, &state, .i64, .f64),
        }
    }
}

fn validateUnaryOp(allocator: Allocator, state: *State, operand: ValType, result: ValType) !void {
    _ = try state.popExpect(operand);
    try state.push(allocator, result);
}

fn validateBinaryOp(allocator: Allocator, state: *State, left: ValType, right: ValType, result: ValType) !void {
    _ = try state.popExpect(left);
    _ = try state.popExpect(right);
    try state.push(allocator, result);
}
