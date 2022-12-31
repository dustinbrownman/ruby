# frozen_string_literal: true
module RubyVM::MJIT
  # https://www.intel.com/content/dam/develop/public/us/en/documents/325383-sdm-vol-2abcd.pdf
  # Mostly an x86_64 assembler, but this also has some stuff that is useful for any architecture.
  class Assembler
    # A thin Fiddle wrapper to write bytes to memory
    ByteWriter = CType::Immediate.parse('char')

    # Used for rel8 jumps
    class Label < Data.define(:id, :name); end

    # rel32 is inserted as [Rel32, Rel32Pad..] and converted on #resolve_rel32
    class Rel32 < Data.define(:addr); end
    Rel32Pad = Object.new

    # A set of ModR/M values encoded on #insn
    class ModRM < Data.define(:mod, :reg, :rm); end
    Mod00 = 0b00 # Mod 00: [reg]
    Mod01 = 0b01 # Mod 01: [reg]+disp8
    Mod10 = 0b10 # Mod 10: [reg]+disp16
    Mod11 = 0b11 # Mod 11: reg

    ### prefix ###
    # REX =   0100WR0B
    REX_B = 0b01000001
    REX_R = 0b01000100
    REX_W = 0b01001000

    def initialize
      @bytes = []
      @labels = {}
      @label_id = 0
      @comments = Hash.new { |h, k| h[k] = [] }
      @stubs = Hash.new { |h, k| h[k] = [] }
    end

    def assemble(addr)
      set_stub_addrs(addr)
      resolve_rel32(addr)
      resolve_labels

      writer = ByteWriter.new(addr)
      # If you pack bytes containing \x00, Ruby fails to recognize bytes after \x00.
      # So writing byte by byte to avoid hitting that situation.
      @bytes.each_with_index do |byte, index|
        writer[index] = byte
      end
      @bytes.size
    ensure
      @bytes.clear
    end

    def size
      @bytes.size
    end

    #
    # Instructions
    #

    def add(dst, src)
      case [dst, src]
      # ADD r/m64, imm8 (Mod 11: reg)
      in [Symbol => dst_reg, Integer => src_imm] if r64?(dst_reg) && imm8?(src_imm)
        # REX.W + 83 /0 ib
        # MI: Operand 1: ModRM:r/m (r, w), Operand 2: imm8/16/32
        insn(
          prefix: REX_W,
          opcode: 0x83,
          mod_rm: ModRM[mod: Mod11, reg: 0, rm: dst_reg],
          imm: imm8(src_imm),
        )
      # ADD r/m64, imm8 (Mod 00: [reg])
      in [[Symbol => dst_reg], Integer => src_imm] if r64?(dst_reg) && imm8?(src_imm)
        # REX.W + 83 /0 ib
        # MI: Operand 1: ModRM:r/m (r, w), Operand 2: imm8/16/32
        insn(
          prefix: REX_W,
          opcode: 0x83,
          mod_rm: ModRM[mod: Mod00, reg: 0, rm: dst_reg],
          imm: imm8(src_imm),
        )
      else
        raise NotImplementedError, "add: not-implemented operands: #{dst.inspect}, #{src.inspect}"
      end
    end

    # @param addr [Integer]
    def call(addr)
      # CALL rel32
      # E8 cd
      insn(opcode: 0xe8, imm: rel32(addr))
    end

    def jmp(dst)
      case dst
      # JMP rel32
      in Integer => dst_addr
        # E9 cd
        insn(opcode: 0xe9, imm: rel32(dst_addr))
      # JMP r/m64 (Mod 11: reg)
      in Symbol => dst_reg
        # FF /4
        insn(opcode: 0xff, mod_rm: ModRM[mod: Mod11, reg: 4, rm: dst_reg])
      else
        raise NotImplementedError, "jmp: not-implemented operands: #{dst.inspect}"
      end
    end

    def jnz(dst)
      case dst
      # JNZ rel32
      in Integer => dst_addr
        # 0F 85 cd
        insn(opcode: [0x0f, 0x85], imm: rel32(dst_addr))
      else
        raise NotImplementedError, "jnz: not-implemented operands: #{dst.inspect}"
      end
    end

    def jz(dst)
      case dst
      # JZ rel8
      in Label => dst_label
        # 74 cb
        insn(opcode: 0x74, imm: dst_label)
      else
        raise NotImplementedError, "jz: not-implemented operands: #{dst.inspect}"
      end
    end

    def mov(dst, src)
      case dst
      in Symbol => dst_reg
        case src
        # MOV r64, r/m64 (Mod 00: [reg])
        in [Symbol => src_reg] if r64?(dst_reg) && r64?(src_reg)
          # REX.W + 8B /r
          # RM: Operand 1: ModRM:reg (w), Operand 2: ModRM:r/m (r)
          insn(
            prefix: REX_W,
            opcode: 0x8b,
            mod_rm: ModRM[mod: Mod00, reg: dst_reg, rm: src_reg],
          )
        # MOV r64, r/m64 (Mod 01: [reg]+disp8)
        in [Symbol => src_reg, Integer => src_disp] if r64?(dst_reg) && r64?(src_reg) && imm8?(src_disp)
          # REX.W + 8B /r
          # RM: Operand 1: ModRM:reg (w), Operand 2: ModRM:r/m (r)
          insn(
            prefix: REX_W,
            opcode: 0x8b,
            mod_rm: ModRM[mod: Mod01, reg: dst_reg, rm: src_reg],
            disp: src_disp,
          )
        # MOV r64, r/m64 (Mod 11: reg)
        in Symbol => src_reg if r64?(dst_reg) && r64?(src_reg)
          # REX.W + 8B /r
          # RM: Operand 1: ModRM:reg (w), Operand 2: ModRM:r/m (r)
          insn(
            prefix: REX_W,
            opcode: 0x8b,
            mod_rm: ModRM[mod: Mod11, reg: dst_reg, rm: src_reg],
          )
        # MOV r32 r/m32 (Mod 01: [reg]+disp8)
        in [Symbol => src_reg, Integer => src_disp] if r32?(dst_reg) && imm8?(src_disp)
          # 8B /r
          # RM: Operand 1: ModRM:reg (w), Operand 2: ModRM:r/m (r)
          insn(
            opcode: 0x8b,
            mod_rm: ModRM[mod: Mod01, reg: dst_reg, rm: src_reg],
            disp: src_disp,
          )
        # MOV r/m64, imm32 (Mod 11: reg)
        in Integer => src_imm if r64?(dst_reg) && imm32?(src_imm)
          # REX.W + C7 /0 id
          # MI: Operand 1: ModRM:r/m (w), Operand 2: imm8/16/32/64
          insn(
            prefix: REX_W,
            opcode: 0xc7,
            mod_rm: ModRM[mod: Mod11, reg: 0, rm: dst_reg],
            imm: imm32(src_imm),
          )
        # MOV r64, imm64
        in Integer => src_imm if r64?(dst_reg) && imm64?(src_imm)
          # REX.W + B8+ rd io
          # OI: Operand 1: opcode + rd (w), Operand 2: imm8/16/32/64
          insn(
            prefix: REX_W,
            opcode: 0xb8,
            rd: dst_reg,
            imm: imm64(src_imm),
          )
        else
          raise NotImplementedError, "mov: not-implemented operands: #{dst.inspect}, #{src.inspect}"
        end
      in [Symbol => dst_reg]
        case src
        # MOV r/m64, imm32 (Mod 00: [reg])
        in Integer => src_imm if r64?(dst_reg) && imm32?(src_imm)
          # REX.W + C7 /0 id
          # MI: Operand 1: ModRM:r/m (w), Operand 2: imm8/16/32/64
          insn(
            prefix: REX_W,
            opcode: 0xc7,
            mod_rm: ModRM[mod: Mod00, reg: 0, rm: dst_reg],
            imm: imm32(src_imm),
          )
        # MOV r/m64, r64 (Mod 00: [reg])
        in Symbol => src_reg if r64?(dst_reg) && r64?(src_reg)
          # REX.W + 89 /r
          # MR: Operand 1: ModRM:r/m (w), Operand 2: ModRM:reg (r)
          insn(
            prefix: REX_W,
            opcode: 0x89,
            mod_rm: ModRM[mod: Mod00, reg: src_reg, rm: dst_reg],
          )
        else
          raise NotImplementedError, "mov: not-implemented operands: #{dst.inspect}, #{src.inspect}"
        end
      in [Symbol => dst_reg, Integer => dst_disp]
        # Optimize encoding when disp is 0
        return mov([dst_reg], src) if dst_disp == 0

        case src
        # MOV r/m64, imm32 (Mod 01: [reg]+disp8)
        in Integer => src_imm if r64?(dst_reg) && imm8?(dst_disp) && imm32?(src_imm)
          # REX.W + C7 /0 id
          # MI: Operand 1: ModRM:r/m (w), Operand 2: imm8/16/32/64
          insn(
            prefix: REX_W,
            opcode: 0xc7,
            mod_rm: ModRM[mod: Mod01, reg: 0, rm: dst_reg],
            disp: dst_disp,
            imm: imm32(src_imm),
          )
        # MOV r/m64, r64 (Mod 01: [reg]+disp8)
        in Symbol => src_reg if r64?(dst_reg) && imm8?(dst_disp) && r64?(src_reg)
          # REX.W + 89 /r
          # MR: Operand 1: ModRM:r/m (w), Operand 2: ModRM:reg (r)
          insn(
            prefix: REX_W,
            opcode: 0x89,
            mod_rm: ModRM[mod: Mod01, reg: src_reg, rm: dst_reg],
            disp: dst_disp,
          )
        else
          raise NotImplementedError, "mov: not-implemented operands: #{dst.inspect}, #{src.inspect}"
        end
      else
        raise NotImplementedError, "mov: not-implemented operands: #{dst.inspect}, #{src.inspect}"
      end
    end

    def push(src)
      case src
      # PUSH r64
      in Symbol => src_reg if r64?(src_reg)
        # 50+rd
        # O: Operand 1: opcode + rd (r)
        insn(opcode: 0x50, rd: src_reg)
      else
        raise NotImplementedError, "push: not-implemented operands: #{src.inspect}"
      end
    end

    def pop(dst)
      case dst
      # POP r64
      in Symbol => dst_reg if r64?(dst_reg)
        # 58+ rd
        # O: Operand 1: opcode + rd (r)
        insn(opcode: 0x58, rd: dst_reg)
      else
        raise NotImplementedError, "pop: not-implemented operands: #{dst.inspect}"
      end
    end

    # RET
    def ret
      # Near return: A return to a procedure within the current code segment
      insn(opcode: 0xc3)
    end

    def test(left, right)
      case [left, right]
      # TEST r/m32, r32 (Mod 11: reg)
      in [Symbol => left_reg, Symbol => right_reg] if r32?(left_reg) && r32?(right_reg)
        # 85 /r
        # MR: Operand 1: ModRM:r/m (r), Operand 2: ModRM:reg (r)
        insn(
          opcode: 0x85,
          mod_rm: ModRM[mod: Mod11, reg: right_reg, rm: left_reg],
        )
      else
        raise NotImplementedError, "pop: not-implemented operands: #{dst.inspect}"
      end
    end

    #
    # Utilities
    #

    attr_reader :comments

    def comment(message)
      @comments[@bytes.size] << message
    end

    def stub(stub)
      @stubs[@bytes.size] << stub
    end

    def new_label(name)
      Label.new(id: @label_id += 1, name:)
    end

    # @param [RubyVM::MJIT::Assembler::Label] label
    def write_label(label)
      @labels[label] = @bytes.size
    end

    def incr_counter(name)
      if C.mjit_opts.stats
        comment("increment counter #{name}")
        mov(:rax, C.rb_mjit_counters[name].to_i)
        add([:rax], 1) # TODO: lock
      end
    end

    def imm32?(imm)
      (-0x8000_0000..0x7fff_ffff).include?(imm) # TODO: consider uimm
    end

    private

    def insn(prefix: 0, opcode:, rd: nil, mod_rm: nil, disp: nil, imm: nil)
      # Determine prefix
      if rd
        prefix |= REX_B if extended_reg?(rd)
        opcode += reg_code(rd)
      end
      if mod_rm
        prefix |= REX_R if mod_rm.reg.is_a?(Symbol) && extended_reg?(mod_rm.reg)
        prefix |= REX_B if mod_rm.rm.is_a?(Symbol) && extended_reg?(mod_rm.rm)
      end

      # Encode insn
      if prefix > 0
        @bytes.push(prefix)
      end
      @bytes.push(*Array(opcode))
      if mod_rm
        mod_rm_byte = encode_mod_rm(
          mod: mod_rm.mod,
          reg: mod_rm.reg.is_a?(Symbol) ? reg_code(mod_rm.reg) : mod_rm.reg,
          rm: mod_rm.rm.is_a?(Symbol) ? reg_code(mod_rm.rm) : mod_rm.rm,
        )
        @bytes.push(mod_rm_byte)
      end
      if disp
        unless imm8?(disp) # TODO: support displacement in 2 or 4 bytes as well
          raise NotImplementedError, "not-implemented disp: #{disp}"
        end
        @bytes.push(disp)
      end
      if imm
        @bytes.push(*imm)
      end
    end

    def reg_code(reg)
      reg_code_extended(reg).first
    end

    def extended_reg?(reg)
      reg_code_extended(reg).last
    end

    def reg_code_extended(reg)
      case reg
      # Not extended
      when :al, :ax, :eax, :rax then [0, false]
      when :cl, :cx, :ecx, :rcx then [1, false]
      when :dl, :dx, :edx, :rdx then [2, false]
      when :bl, :bx, :ebx, :rbx then [3, false]
      when :ah, :sp, :esp, :rsp then [4, false]
      when :ch, :bp, :ebp, :rbp then [5, false]
      when :dh, :si, :esi, :rsi then [6, false]
      when :bh, :di, :edi, :rdi then [7, false]
      # Extended
      when :r8b,  :r8w,  :r8d,  :r8  then [0, true]
      when :r9b,  :r9w,  :r9d,  :r9  then [1, true]
      when :r10b, :r10w, :r10d, :r10 then [2, true]
      when :r11b, :r11w, :r11d, :r11 then [3, true]
      when :r12b, :r12w, :r12d, :r12 then [4, true]
      when :r13b, :r13w, :r13d, :r13 then [5, true]
      when :r14b, :r14w, :r14d, :r14 then [6, true]
      when :r15b, :r15w, :r15d, :r15 then [7, true]
      else raise ArgumentError, "unexpected reg: #{reg.inspect}"
      end
    end

    # Table 2-2. 32-Bit Addressing Forms with the ModR/M Byte
    #
    #  7  6  5  4  3  2  1  0
    # +--+--+--+--+--+--+--+--+
    # | Mod | Reg/   | R/M    |
    # |     | Opcode |        |
    # +--+--+--+--+--+--+--+--+
    #
    # The r/m field can specify a register as an operand or it can be combined
    # with the mod field to encode an addressing mode.
    #
    # /0: R/M is 0 (not used)
    # /r: R/M is a register
    def encode_mod_rm(mod:, reg: 0, rm: 0)
      if mod > 0b11
        raise ArgumentError, "too large Mod: #{mod}"
      end
      if reg > 0b111
        raise ArgumentError, "too large Reg/Opcode: #{reg}"
      end
      if rm > 0b111
        raise ArgumentError, "too large R/M: #{rm}"
      end
      (mod << 6) + (reg << 3) + rm
    end

    # ib: 1 byte
    def imm8(imm)
      unless imm8?(imm)
        raise ArgumentError, "unexpected imm8: #{imm}"
      end
      imm_bytes(imm, 1)
    end

    # id: 4 bytes
    def imm32(imm)
      unless imm32?(imm)
        raise ArgumentError, "unexpected imm32: #{imm}"
      end
      [imm].pack('l').unpack('c*')
    end

    # io: 8 bytes
    def imm64(imm)
      unless imm64?(imm)
        raise ArgumentError, "unexpected imm64: #{imm}"
      end
      imm_bytes(imm, 8)
    end

    def imm_bytes(imm, num_bytes)
      bytes = []
      bits = imm
      num_bytes.times do
        bytes << (bits & 0xff)
        bits >>= 8
      end
      if bits != 0
        raise ArgumentError, "unexpected imm with #{num_bytes} bytes: #{imm}"
      end
      bytes
    end

    def imm8?(imm)
      (-0x80..0x7f).include?(imm)
    end

    def imm64?(imm)
      (-0x8000_0000_0000_0000..0x7fff_ffff_ffff_ffff).include?(imm) # TODO: consider uimm
    end

    def r32?(reg)
      if extended_reg?(reg)
        reg.end_with?('d')
      else
        reg.start_with?('e')
      end
    end

    def r64?(reg)
      if extended_reg?(reg)
        reg.match?(/\Ar\d+\z/)
      else
        reg.start_with?('r')
      end
    end

    def rel32(addr)
      [Rel32.new(addr), Rel32Pad, Rel32Pad, Rel32Pad]
    end

    def set_stub_addrs(write_addr)
      @bytes.each_with_index do |byte, index|
        @stubs.fetch(index, []).each do |stub|
          stub.addr = write_addr + index
          stub.freeze
        end
      end
    end

    def resolve_rel32(write_addr)
      @bytes.each_with_index do |byte, index|
        if byte.is_a?(Rel32)
          src_addr = write_addr + index + 4 # offset 4 bytes for rel32 itself
          dst_addr = byte.addr
          rel32 = dst_addr - src_addr
          raise "unexpected offset: #{rel32}" unless imm32?(rel32)
          imm32(rel32).each_with_index do |rel_byte, rel_index|
            @bytes[index + rel_index] = rel_byte
          end
        end
      end
    end

    def resolve_labels
      @bytes.each_with_index do |byte, index|
        if byte.is_a?(Label)
          src_index = index + 1 # offset 1 byte for rel8 itself
          dst_index = @labels.fetch(byte)
          rel8 = dst_index - src_index
          raise "unexpected offset: #{rel8}" unless imm8?(rel8)
          @bytes[index] = rel8
        end
      end
    end
  end
end