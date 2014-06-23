-- Accelerated 6502-like CPU for the C65GS
--
-- Written by
--    Paul Gardner-Stephen <hld@c64.org>
--
-- * ADC/SBC algorithm derived from  6510core.c - WICE MOS6510 emulation core.
-- *   Written by
-- *    Ettore Perazzoli <ettore@comm2000.it>
-- *    Andreas Boose <viceteam@t-online.de>
-- *
-- *  This program is free software; you can redistribute it and/or modify
-- *  it under the terms of the GNU Lesser General Public License as
-- *  published by the Free Software Foundation; either version 2 of the
-- *  License, or (at your option) any later version.
-- *
-- *  This program is distributed in the hope that it will be useful,
-- *  but WITHOUT ANY WARRANTY; without even the implied warranty of
-- *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- *  GNU General Public License for more details.
-- *
-- *  You should have received a copy of the GNU Lesser General Public License
-- *  along with this program; if not, write to the Free Software
-- *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
-- *  02111-1307  USA.

use WORK.ALL;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;

entity gs4510 is
  port (
    Clock : in std_logic;
    reset : in std_logic;
    irq : in std_logic;
    nmi : in std_logic;
    monitor_pc : out std_logic_vector(15 downto 0);
    monitor_watch : in std_logic_vector(27 downto 0);
    monitor_watch_match : out std_logic;
    monitor_opcode : out std_logic_vector(7 downto 0);
    monitor_ibytes : out std_logic_vector(3 downto 0);
    monitor_arg1 : out std_logic_vector(7 downto 0);
    monitor_arg2 : out std_logic_vector(7 downto 0);
    monitor_a : out std_logic_vector(7 downto 0);
    monitor_x : out std_logic_vector(7 downto 0);
    monitor_y : out std_logic_vector(7 downto 0);
    monitor_z : out std_logic_vector(7 downto 0);
    monitor_b : out std_logic_vector(7 downto 0);
    monitor_sp : out std_logic_vector(15 downto 0);
    monitor_p : out std_logic_vector(7 downto 0);
    monitor_state : out std_logic_vector(7 downto 0);
    monitor_interrupt_inhibit : out std_logic;
    monitor_map_offset_low : out std_logic_vector(11 downto 0);
    monitor_map_offset_high : out std_logic_vector(11 downto 0);
    monitor_map_enables_low : out std_logic_vector(3 downto 0);
    monitor_map_enables_high : out std_logic_vector(3 downto 0);   
    
    ---------------------------------------------------------------------------
    -- Memory access interface used by monitor
    ---------------------------------------------------------------------------
    monitor_mem_address : in std_logic_vector(27 downto 0);
    monitor_mem_rdata : out unsigned(7 downto 0);
    monitor_mem_wdata : in unsigned(7 downto 0);
    monitor_mem_read : in std_logic;
    monitor_mem_write : in std_logic;
    monitor_mem_setpc : in std_logic;
    monitor_mem_attention_request : in std_logic;
    monitor_mem_attention_granted : out std_logic := '0';
    monitor_mem_trace_mode : in std_logic;
    monitor_mem_stage_trace_mode : in std_logic;
    monitor_mem_trace_toggle : in std_logic;
    
    ---------------------------------------------------------------------------
    -- Interface to FastRAM in video controller (just 128KB for now)
    ---------------------------------------------------------------------------
    fastramwaitstate : in std_logic;
    fastram_we : OUT STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
    fastram_address : OUT STD_LOGIC_VECTOR(13 DOWNTO 0) := "00000000000000";
    fastram_datain : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
    fastram_dataout : IN STD_LOGIC_VECTOR(63 DOWNTO 0) := x"0000000000000000";

    ---------------------------------------------------------------------------
    -- Interface to Slow RAM (16MB cellular RAM chip)
    ---------------------------------------------------------------------------
    slowram_addr : out std_logic_vector(22 downto 0);
    slowram_we : out std_logic := '0';
    slowram_ce : out std_logic := '0';
    slowram_oe : out std_logic := '0';
    slowram_lb : out std_logic := '0';
    slowram_ub : out std_logic := '0';
    slowram_data : inout std_logic_vector(15 downto 0);
    
    ---------------------------------------------------------------------------
    -- fast IO port (clocked at core clock). 1MB address space
    ---------------------------------------------------------------------------
    fastio_addr : inout std_logic_vector(19 downto 0);
    fastio_read : inout std_logic;
    fastio_write : inout std_logic;
    fastio_wdata : out std_logic_vector(7 downto 0);
    fastio_rdata : in std_logic_vector(7 downto 0);
    fastio_sd_rdata : in std_logic_vector(7 downto 0);
    sector_buffer_mapped : in std_logic;
    fastio_vic_rdata : in std_logic_vector(7 downto 0);
    fastio_colour_ram_rdata : in std_logic_vector(7 downto 0);
    colour_ram_cs : out std_logic;

    viciii_iomode : in std_logic_vector(1 downto 0);

    colourram_at_dc00 : in std_logic;
    rom_at_e000 : in std_logic;
    rom_at_c000 : in std_logic;
    rom_at_a000 : in std_logic;
    rom_at_8000 : in std_logic
    );
end entity gs4510;

architecture Behavioural of gs4510 is

  component shadowram is
      port (Clk : in std_logic;
            address : in std_logic_vector(17 downto 0);            
            we : in std_logic;
            -- chip select, active low       
            cs : in std_logic;
            data_i : in std_logic_vector(7 downto 0);
            data_o : out std_logic_vector(7 downto 0)
        );
  end component;
  
  signal kickstart_en : std_logic := '1';
  signal colour_ram_cs_last : std_logic := '0';

--  signal fastram_last_address : std_logic_vector(13 downto 0);

  -- Shadow RAM control
  signal shadow_bank : unsigned(7 downto 0);
  signal shadow_address : unsigned(17 downto 0);
  signal shadow_rdata : unsigned(7 downto 0);
  signal shadow_wdata : unsigned(7 downto 0);
  signal shadow_write : std_logic := '0';
  
  -- i-cache control lines
  signal icache_delay : std_logic;
  signal accessing_icache : std_logic;

  signal icache_00_address : unsigned(7 downto 0);
  signal icache_00_wdata : unsigned(31 downto 0);
  signal icache_00_write : std_logic;
  signal icache_01_address : unsigned(7 downto 0);
  signal icache_01_wdata : unsigned(31 downto 0);
  signal icache_01_write : std_logic;
  signal icache_10_address : unsigned(7 downto 0);
  signal icache_10_wdata : unsigned(31 downto 0);
  signal icache_10_write : std_logic;
  signal icache_11_address : unsigned(7 downto 0);
  signal icache_11_wdata : unsigned(31 downto 0);
  signal icache_11_write : std_logic;
  
  signal last_fastio_addr : std_logic_vector(19 downto 0);

  signal slowram_lohi : std_logic;
  signal slowram_counter : unsigned(7 downto 0);
  -- SlowRAM has 70ns access time, so need some wait states.
  -- The wait states
  signal slowram_waitstates : unsigned(7 downto 0) := x"05";
  
  signal fastram_byte_number : unsigned(2 DOWNTO 0);

  signal word_flag : std_logic := '0';

  -- DMAgic registers
  signal reg_dmagic_addr : unsigned(27 downto 0) := x"0000000";
  signal reg_dmagic_withio : std_logic;
  signal reg_dmagic_status : unsigned(7 downto 0) := x"00";
  signal reg_dmacount : unsigned(7 downto 0) := x"00";  -- number of DMA jobs done
  signal dma_pending : std_logic := '0';
  signal dma_checksum : unsigned(23 downto 0) := x"000000";
  signal dmagic_cmd : unsigned(7 downto 0);
  signal dmagic_count : unsigned(15 downto 0);
  signal dmagic_tally : unsigned(15 downto 0);
  signal dmagic_src_addr : unsigned(27 downto 0);
  signal dmagic_src_io : std_logic;
  signal dmagic_src_direction : std_logic;
  signal dmagic_src_modulo : std_logic;
  signal dmagic_src_hold : std_logic;
  signal dmagic_dest_addr : unsigned(27 downto 0);
  signal dmagic_dest_io : std_logic;
  signal dmagic_dest_direction : std_logic;
  signal dmagic_dest_modulo : std_logic;
  signal dmagic_dest_hold : std_logic;
  signal dmagic_modulo : unsigned(15 downto 0);

  -- CPU internal state
  signal flag_c : std_logic;        -- carry flag
  signal flag_z : std_logic;        -- zero flag
  signal flag_d : std_logic;        -- decimal mode flag
  signal flag_n : std_logic;        -- negative flag
  signal flag_v : std_logic;        -- positive flag
  signal flag_i : std_logic;        -- interrupt disable flag
  signal flag_e : std_logic;        -- 8-bit stack flag

  signal reg_a : unsigned(7 downto 0);
  signal reg_b : unsigned(7 downto 0);
  signal reg_x : unsigned(7 downto 0);
  signal reg_y : unsigned(7 downto 0);
  signal reg_z : unsigned(7 downto 0);
  signal reg_sp : unsigned(7 downto 0);
  signal reg_sph : unsigned(7 downto 0);
  signal reg_pc : unsigned(15 downto 0);

  -- CPU RAM bank selection registers.
  -- Now C65 style, but extended by 8 bits to give 256MB address space
  signal reg_mb_low : unsigned(7 downto 0);
  signal reg_mb_high : unsigned(7 downto 0);
  signal reg_map_low : std_logic_vector(3 downto 0);
  signal reg_map_high : std_logic_vector(3 downto 0);
  signal reg_offset_low : unsigned(11 downto 0);
  signal reg_offset_high : unsigned(11 downto 0);

  -- Flags to detect interrupts
  signal map_interrupt_inhibit : std_logic := '0';
  signal nmi_pending : std_logic := '0';
  signal irq_pending : std_logic := '0';
  signal nmi_state : std_logic := '1';
  -- Interrupt/reset vector being used
  signal vector : unsigned(15 downto 0);
  
  type processor_state is (
    -- When CPU first powers up, or reset is bought low
    ResetLow,
    -- States for handling interrupts and reset
    Interrupt,VectorRead,VectorRead1,VectorRead2,VectorRead3,
    DMAgic0,DMAgic1,DMAgic2,DMAgic3,DMAgic4,DMAgic5,DMAgic6,DMAgic7,
    DMAgic8,DMAgic9,DMAgic10,DMAgic11,DMAgic12,DMAgic13,DMAgic14,DMAgic15,
    InstructionDispatch,InstructionFetch,
    InstructionFetch2,InstructionFetch3,InstructionFetch4,
    BRK1,BRK2,PLA1,PLX1,PLY1,PLZ1,PLP1,RTI1,RTI2,RTI3,
    RTS1,RTS2,
    JSR1,JSRind1,JSRind2,JSRind3,JSRind4,
    JMP1,JMP2,JMP3,
    PHWimm1,PHWabs1,PHWabs2,PHWabs3,
    IndirectX1,IndirectX2,IndirectX3,
    IndirectY1,IndirectY2,IndirectY3,
    IndirectZ1,IndirectZ2,
    ExecuteDirect,RMWCommit,RMWCommit2,RMWCommit3,
    Halt, -- FastRamWait,
    SlowRamRead1,SlowRamRead2,SlowRamWrite1,SlowRamWrite2,
    BranchOnBit,
    MonitorAccessDone,MonitorReadDone,
    Interrupt2,Interrupt3,FastIOWait
    );
  signal state : processor_state := ResetLow;  -- start processor in reset state
  -- For memory access we push the processor state to follow once the memory
  -- access is complete.
  signal pending_state : processor_state;
  -- Information about instruction currently being executed
  signal opcode : unsigned(7 downto 0);
  signal arg1 : unsigned(7 downto 0);
  signal arg2 : unsigned(7 downto 0);

  signal bbs_or_bbc : std_logic;
  signal bbs_bit : unsigned(2 downto 0);
    
  -- PC used for JSR is the value of reg_pc after reading only one of
  -- of the argument bytes.  We could subtract one, but it is less logic to
  -- just remember PC after reading one argument byte.
  signal reg_pc_jsr : unsigned(15 downto 0);
  -- Temporary address register (used for indirect modes)
  signal reg_addr : unsigned(15 downto 0);
  -- Temporary instruction register (used for many modes)
  signal reg_opcode : unsigned(7 downto 0);
  -- Temporary value holder (used for RMW instructions)
  signal reg_value : unsigned(7 downto 0);
  
-- Indicate source of operand for instructions
-- Note that ROM is actually implemented using
-- power-on initialised RAM in the FPGA mapped via our io interface.
  signal accessing_shadow : std_logic;
  signal accessing_fastio : std_logic;
  signal accessing_sb_fastio : std_logic;
  signal accessing_vic_fastio : std_logic;
  signal accessing_colour_ram_fastio : std_logic;
--  signal accessing_ram : std_logic;
  signal accessing_slowram : std_logic;
  signal accessing_cpuport : std_logic;
  signal cpuport_num : std_logic;
  signal cpuport_ddr : unsigned(7 downto 0) := x"FF";
  signal cpuport_value : unsigned(7 downto 0) := x"3F";
  signal the_read_address : unsigned(27 downto 0);
  
  signal monitor_mem_trace_toggle_last : std_logic := '0';

begin

  shadowram0 : shadowram port map (
    clk     => clock,
    address => std_logic_vector(shadow_address),
    we      => shadow_write,
    cs      => '1',
    data_i  => std_logic_vector(shadow_wdata),
    unsigned(data_o)  => shadow_rdata);
  
  process(clock)

    procedure reset_cpu_state is
  begin
    -- Default register values
    reg_b <= x"00";
    reg_a <= x"11";    
    reg_x <= x"22";
    reg_y <= x"33";
    reg_z <= x"00";
    reg_sp <= x"ff";
    reg_sph <= x"01";

    -- Clear CPU MMU registers
    reg_mb_low <= x"00";
    reg_mb_high <= x"00";
    reg_map_low <= "0000";
    reg_map_high <= "0000";
    reg_offset_low <= x"000";
    reg_offset_high <= x"000";

    -- On boot up, don't shadow chipram.
    -- Instead shadow unmapped address space at $C0000 (768KB)
    shadow_bank <= x"0C";
    
    -- Default CPU flags
    flag_c <= '0';
    flag_d <= '0';
    flag_i <= '1';                -- start with IRQ disabled
    flag_z <= '0';
    flag_n <= '0';
    flag_v <= '0';
    flag_e <= '1';

    cpuport_ddr <= x"FF";
    cpuport_value <= x"3F";

    -- Don't write to fastio when resetting.
    -- (this is an attempt to stop the boot vectors getting overwritten)
    fastio_write <= '0'; fastio_read <= '0'; shadow_write <= '0';

  end procedure reset_cpu_state;

  procedure check_for_interrupts is
  begin
    -- No interrupts of any sort between MAP and EOM instructions.
    if map_interrupt_inhibit='0' then
      -- NMI is edge triggered.
      if nmi = '0' and nmi_state = '1' then
        nmi_pending <= '1';        
      end if;
      nmi_state <= nmi;
      -- IRQ is level triggered.
      if irq = '0' then
        irq_pending <= '1';
      else
        irq_pending <= '0';
      end if;
    else
      irq_pending <= '0';
    end if;     
  end procedure check_for_interrupts;

  -- purpose: Convert a 16-bit C64 address to native RAM (or I/O or ROM) address
  impure function resolve_address_to_long(short_address : unsigned(15 downto 0);
                                          writeP : boolean)
    return unsigned is 
    variable temp_address : unsigned(27 downto 0);
    variable blocknum : integer;
    variable lhc : std_logic_vector(2 downto 0);
  begin  -- resolve_long_address

    -- Now apply C64-style $01 lines first, because MAP and $D030 take precedence
    blocknum := to_integer(short_address(15 downto 12));

    lhc := std_logic_vector(cpuport_value(2 downto 0));
    lhc(2) := lhc(2) or (not cpuport_ddr(2));
    lhc(1) := lhc(1) or (not cpuport_ddr(1));
    lhc(0) := lhc(0) or (not cpuport_ddr(0));
    
    -- Examination of the C65 interface ROM reveals that MAP instruction
    -- takes precedence over $01 CPU port when MAP bit is set for a block of RAM.

    -- From https://groups.google.com/forum/#!topic/comp.sys.cbm/C9uWjgleTgc
    -- Port pin (bit)    $A000 to $BFFF       $D000 to $DFFF       $E000 to $FFFF
    -- 2 1 0             Read       Write     Read       Write     Read       Write
    -- --------------    ----------------     ----------------     ----------------
    -- 0 0 0             RAM        RAM       RAM        RAM       RAM        RAM
    -- 0 0 1             RAM        RAM       CHAR-ROM   RAM       RAM        RAM
    -- 0 1 0             RAM        RAM       CHAR-ROM   RAM       KERNAL-ROM RAM
    -- 0 1 1             BASIC-ROM  RAM       CHAR-ROM   RAM       KERNAL-ROM RAM
    -- 1 0 0             RAM        RAM       RAM        RAM       RAM        RAM
    -- 1 0 1             RAM        RAM       I/O        I/O       RAM        RAM
    -- 1 1 0             RAM        RAM       I/O        I/O       KERNAL-ROM RAM
    -- 1 1 1             BASIC-ROM  RAM       I/O        I/O       KERNAL-ROM RAM
    
    -- default is address in = address out
    temp_address(27 downto 16) := (others => '0');
    temp_address(15 downto 0) := short_address;

    -- IO
    if (blocknum=13) then
      temp_address(11 downto 0) := short_address(11 downto 0);
      if writeP then
        case lhc(2 downto 0) is
          when "000" => temp_address(27 downto 12) := x"000D";  -- WRITE RAM
          when "001" => temp_address(27 downto 12) := x"000D";  -- WRITE RAM
          when "010" => temp_address(27 downto 12) := x"000D";  -- WRITE RAM
          when "011" => temp_address(27 downto 12) := x"000D";  -- WRITE RAM
          when "100" => temp_address(27 downto 12) := x"000D";  -- WRITE RAM
          when others =>
            -- All else accesses IO
            -- C64/C65/C65GS I/O is based on which secret knock has been applied
            -- to $D02F
            temp_address(27 downto 12) := x"FFD3";
            temp_address(13 downto 12) := unsigned(viciii_iomode);          
        end case;        
      else
        -- READING
        case lhc(2 downto 0) is
          when "000" => temp_address(27 downto 12) := x"000D";  -- READ RAM
          when "001" => temp_address(27 downto 12) := x"002D";  -- CHARROM
          when "010" => temp_address(27 downto 12) := x"002D";  -- CHARROM
          when "011" => temp_address(27 downto 12) := x"002D";  -- CHARROM
          when "100" => temp_address(27 downto 12) := x"000D";  -- READ RAM
          when others =>
            -- All else accesses IO
            -- C64/C65/C65GS I/O is based on which secret knock has been applied
            -- to $D02F
            temp_address(27 downto 12) := x"FFD3";
            temp_address(13 downto 12) := unsigned(viciii_iomode);          
        end case;              end if;
    end if;

    -- C64 KERNEL
    if reg_map_high(3)='0' then
      if (blocknum=14) and (lhc(1)='1') and (writeP=false) then
        temp_address(27 downto 12) := x"002E";      
      end if;
      if (blocknum=15) and (lhc(1)='1') and (writeP=false) then
        temp_address(27 downto 12) := x"002F";      
      end if;
    end if;
    -- C64 BASIC
    if reg_map_high(1)='0' then
      if (blocknum=10) and (lhc(0)='1') and (lhc(1)='1') and (writeP=false) then
        temp_address(27 downto 12) := x"002A";      
      end if;
      if (blocknum=11) and (lhc(0)='1') and (lhc(1)='1') and (writeP=false) then
        temp_address(27 downto 12) := x"002B";      
      end if;
    end if;

    -- Lower 8 address bits are never changed
    temp_address(7 downto 0):=short_address(7 downto 0);

    -- Add the map offset if required
    blocknum := to_integer(short_address(14 downto 13));
    if short_address(15)='1' then
      if reg_map_high(blocknum)='1' then
        temp_address(27 downto 20) := reg_mb_high;
        temp_address(19 downto 8) := reg_offset_high+to_integer(short_address(15 downto 8));
        temp_address(7 downto 0) := short_address(7 downto 0);       
      end if;
    else
      if reg_map_low(blocknum)='1' then
        temp_address(27 downto 20) := reg_mb_low;
        temp_address(19 downto 8) := reg_offset_low+to_integer(short_address(15 downto 8));
        temp_address(7 downto 0) := short_address(7 downto 0);
        report "mapped memory address is $" & to_hstring(temp_address) severity note;
      end if;
    end if;
    
    -- $D030 ROM select lines:
    blocknum := to_integer(short_address(15 downto 12));
    if (blocknum=14 or blocknum=15) and rom_at_e000='1' then
      temp_address(27 downto 12) := x"003E";
      if blocknum=15 then temp_address(12):='1'; end if;
    end if;
    if (blocknum=12) and rom_at_c000='1' then
      temp_address(27 downto 12) := x"002C";
    end if;
    if (blocknum=10 or blocknum=11) and rom_at_a000='1' then
      temp_address(27 downto 12) := x"003A";
      if blocknum=11 then temp_address(12):='1'; end if;
    end if;
    if (blocknum=9) and rom_at_8000='1' then
      temp_address(27 downto 12) := x"0039";
    end if;
    if (blocknum=8) and rom_at_8000='1' then
      temp_address(27 downto 12) := x"0038";
    end if;
    
    -- Kickstart ROM (takes precedence over all else if enabled)
    if (blocknum=14) and (kickstart_en='1') and (writeP=false) then
      temp_address(27 downto 12) := x"FFFE";      
    end if;
    if (blocknum=15) and (kickstart_en='1') and (writeP=false) then
      temp_address(27 downto 12) := x"002F";      
      temp_address(27 downto 12) := x"FFFF";      
    end if;
    
    return temp_address;
  end resolve_address_to_long;

  -- purpose: invalidate cache lines corresponding to a memory write
  procedure icache_invalidate (
    long_address : in unsigned(27 downto 0)) is
  begin  -- icache_invalidate
    case long_address(1 downto 0) is
      when "00" => icache_00_address <= long_address(9 downto 2);
                   icache_00_wdata <= (others => '0');
                   icache_00_write <= '1';
      when "01" => icache_01_address <= long_address(9 downto 2);
                   icache_01_wdata <= (others => '0');
                   icache_01_write <= '1';
      when "10" => icache_10_address <= long_address(9 downto 2);
                   icache_10_wdata <= (others => '0');
                   icache_10_write <= '1';
      when "11" => icache_11_address <= long_address(9 downto 2);
                   icache_11_wdata <= (others => '0');
                   icache_11_write <= '1';
      when others => null;
    end case;
  end icache_invalidate;
  
  -- purpose: set processor flags from a byte (eg for PLP or RTI)
  procedure load_processor_flags (
    value : in unsigned(7 downto 0)) is
  begin  -- load_processor_flags
    flag_n <= value(7);
    flag_v <= value(6);
    -- C65/4502 specifications says that E is not set by PLP, only by SEE/CLE
    flag_d <= value(3);
    flag_i <= value(2);
    flag_z <= value(1);
    flag_c <= value(0);
  end procedure load_processor_flags;

  impure function with_nz (
    value : unsigned(7 downto 0)) return unsigned is
  begin
    -- report "calculating N & Z flags on result $" & to_hstring(value) severity note;
    flag_n <= value(7);
    if value(7 downto 0) = x"00" then
      flag_z <= '1';
    else
      flag_z <= '0';
    end if;
    return value;
  end with_nz;        

  -- purpose: change memory map, C65-style
  procedure c65_map_instruction is
    variable offset : unsigned(15 downto 0);
  begin  -- c65_map_instruction
    -- This is how this instruction works:
    --                            Mapper Register Data
    --    7       6       5       4       3       2       1       0    BIT
    --+-------+-------+-------+-------+-------+-------+-------+-------+
    --| LOWER | LOWER | LOWER | LOWER | LOWER | LOWER | LOWER | LOWER | A
    --| OFF15 | OFF14 | OFF13 | OFF12 | OFF11 | OFF10 | OFF9  | OFF8  |
    --+-------+-------+-------+-------+-------+-------+-------+-------+
    --| MAP   | MAP   | MAP   | MAP   | LOWER | LOWER | LOWER | LOWER | X
    --| BLK3  | BLK2  | BLK1  | BLK0  | OFF19 | OFF18 | OFF17 | OFF16 |
    --+-------+-------+-------+-------+-------+-------+-------+-------+
    --| UPPER | UPPER | UPPER | UPPER | UPPER | UPPER | UPPER | UPPER | Y
    --| OFF15 | OFF14 | OFF13 | OFF12 | OFF11 | OFF10 | OFF9  | OFF8  |
    --+-------+-------+-------+-------+-------+-------+-------+-------+
    --| MAP   | MAP   | MAP   | MAP   | UPPER | UPPER | UPPER | UPPER | Z
    --| BLK7  | BLK6  | BLK5  | BLK4  | OFF19 | OFF18 | OFF17 | OFF16 |
    --+-------+-------+-------+-------+-------+-------+-------+-------+
    --
    
    -- C65GS extension: Set the MegaByte register for low and high mobies
    -- so that we can address all 256MB of RAM.
    if reg_x = x"0f" then
      reg_mb_low <= reg_a;
    end if;
    if reg_z = x"0f" then
      reg_mb_high <= reg_y;
    end if;

    reg_offset_low <= reg_x(3 downto 0) & reg_a;
    reg_map_low <= std_logic_vector(reg_x(7 downto 4));
    reg_offset_high <= reg_z(3 downto 0) & reg_y;
    reg_map_high <= std_logic_vector(reg_z(7 downto 4));
    
  end c65_map_instruction;

  procedure alu_op_cmp (
    i1 : in unsigned(7 downto 0);
    i2 : in unsigned(7 downto 0)) is
    variable result : unsigned(8 downto 0);
  begin
    result := ("0"&i1) - ("0"&i2);
    flag_z <= '0'; flag_c <= '0';
    if result(7 downto 0)=x"00" then
      flag_z <= '1';
    end if;
    if result(8)='0' then
      flag_c <= '1';
    end if;
    flag_n <= result(7);
  end alu_op_cmp;
  
  impure function alu_op_add (
    i1 : in unsigned(7 downto 0);
    i2 : in unsigned(7 downto 0)) return unsigned is
    variable tmp : unsigned(8 downto 0);
  begin
    if flag_d='1' then
      tmp(8) := '0';
      tmp(7 downto 0) := (i1 and x"0f") + (i2 and x"0f") + ("0000000" & flag_c);
      
      if tmp > x"09" then
        tmp := tmp + x"06";                                                                         
      end if;
      if tmp < x"10" then
        tmp := (tmp and x"0f") + (i1 and x"f0") + (i2 and x"f0");
      else
        tmp := (tmp and x"0f") + (i1 and x"f0") + (i2 and x"f0") + x"10";
      end if;
      if (i1 + i2 + ( "0000000" & flag_c )) = x"00" then
        flag_z <= '1';
      else
        flag_z <= '0';
      end if;
      flag_n <= tmp(7);
      flag_v <= (i1(7) xor tmp(7)) and (not (i1(7) xor i2(7)));
      if tmp(8 downto 4) > "01001" then
        tmp(7 downto 0) := tmp(7 downto 0) + x"60";
        tmp(8) := '1';
      end if;
      flag_c <= tmp(8);
    else
      tmp := ("0"&i2)
             + ("0"&i1)
             + ("00000000"&flag_c);
      tmp(7 downto 0) := with_nz(tmp(7 downto 0));
      flag_v <= (not (i1(7) xor i2(7))) and (i1(7) xor tmp(7));
      flag_c <= tmp(8);
    end if;
    -- Return final value
    report "add result of "
      & "$" & to_hstring(std_logic_vector(i1)) 
      & " + "
      & "$" & to_hstring(std_logic_vector(i2)) 
      & " + "
      & "$" & std_logic'image(flag_c)
      & " = " & to_hstring(std_logic_vector(tmp(7 downto 0))) severity note;
    return tmp(7 downto 0);
  end function alu_op_add;

  impure function alu_op_sub (
    i1 : in unsigned(7 downto 0);
    i2 : in unsigned(7 downto 0)) return unsigned is
    variable tmp : unsigned(8 downto 0);
    variable tmpd : unsigned(8 downto 0);
  begin
    tmp := ("0"&i1) - ("0"&i2)
           - "000000001" + ("00000000"&flag_c);
    flag_c <= not tmp(8);
    flag_v <= (i1(7) xor tmp(7)) and (i1(7) xor i2(7));
    tmp(7 downto 0) := with_nz(tmp(7 downto 0));
    if flag_d='1' then
      tmpd := (("00000"&i1(3 downto 0)) - ("00000"&i2(3 downto 0)))
              - "000000001" + ("00000000" & flag_c);

      if tmpd(4)='1' then
        tmpd(3 downto 0) := tmpd(3 downto 0)-x"6";
        tmpd(8 downto 4) := ("0"&i1(7 downto 4)) - ("0"&i2(7 downto 4)) - "00001";
      else
        tmpd(8 downto 4) := ("0"&i1(7 downto 4)) - ("0"&i2(7 downto 4));
      end if;
      if tmpd(8)='1' then
        tmpd := tmpd - ("0"&x"60");
      end if;
      tmp := tmpd;
    end if;
    -- Return final value
    report "subtraction result of "
      & "$" & to_hstring(std_logic_vector(i1)) 
      & " - "
      & "$" & to_hstring(std_logic_vector(i2)) 
      & " - 1 + "
      & "$" & std_logic'image(flag_c)
      & " = " & to_hstring(std_logic_vector(tmp(7 downto 0))) severity note;
    return tmp(7 downto 0);
  end function alu_op_sub;
  
  function flag_status (
    yes : in string;
    no : in string;
    condition : in std_logic) return string is
  begin
    if condition='1' then
      return yes;
    else
      return no;
    end if;
  end function flag_status;
  
  variable virtual_reg_p : std_logic_vector(7 downto 0);
  variable temp_pc : unsigned(15 downto 0);
  variable temp_value : unsigned(7 downto 0);
  variable nybl : unsigned(3 downto 0);

  variable execute_now : std_logic := '0';
  variable execute_opcode : unsigned(7 downto 0);
  variable execute_arg1 : unsigned(7 downto 0);
  variable execute_arg2 : unsigned(7 downto 0);
  begin

    -- BEGINNING OF MAIN PROCESS FOR CPU
    if rising_edge(clock) then     
      -- clear memory access states
      colour_ram_cs <= '0';
      colour_ram_cs_last <= '0';
      -- accessing_ram <= '0'; 
      accessing_slowram <= '0';
      accessing_fastio <= '0'; accessing_vic_fastio <= '0';
      accessing_cpuport <= '0'; accessing_shadow <= '0';
      shadow_write <= '0';

      monitor_watch_match <= '0';       -- set if writing to watched address
      monitor_state <= std_logic_vector(to_unsigned(processor_state'pos(state),8));
      monitor_pc <= std_logic_vector(reg_pc);
      monitor_a <= std_logic_vector(reg_a);
      monitor_x <= std_logic_vector(reg_x);
      monitor_y <= std_logic_vector(reg_y);
      monitor_z <= std_logic_vector(reg_z);
      monitor_sp <= std_logic_vector(reg_sph) & std_logic_vector(reg_sp);
      monitor_b <= std_logic_vector(reg_b);
      monitor_interrupt_inhibit <= map_interrupt_inhibit;
      monitor_map_offset_low <= std_logic_vector(reg_offset_low);
      monitor_map_offset_high <= std_logic_vector(reg_offset_high); 
      monitor_map_enables_low <= std_logic_vector(reg_map_low); 
      monitor_map_enables_high <= std_logic_vector(reg_map_high); 
      
      -- Clear memory access interfaces
      -- Allow fastio to continue reading to support 1 cycle wait state
      -- for those fastio addresses that require it.
      -- XXX This can have problems for reading from registers that have
      -- special side effects.
      accessing_fastio <= '0';
      accessing_vic_fastio <= '0';
      if accessing_fastio='0' then
        fastio_addr <= (others => '1');
        fastio_read <= '0';
      else
        fastio_addr <= last_fastio_addr;
      end if;
      fastio_write <= '0';
      fastram_we <= (others => '0');
      -- fastram_address <= "11111111111111";
      fastram_datain <= x"d0d1d2d3d4d5d6d7";

      -- Generate virtual processor status register for convenience
      virtual_reg_p(7) := flag_n;
      virtual_reg_p(6) := flag_v;
      virtual_reg_p(5) := flag_e;
      virtual_reg_p(4) := '0';
      virtual_reg_p(3) := flag_d;
      virtual_reg_p(2) := flag_i;
      virtual_reg_p(1) := flag_z;
      virtual_reg_p(0) := flag_c;

      monitor_p <= std_logic_vector(virtual_reg_p);
      
    end if;
  end process;

end Behavioural;
