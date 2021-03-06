LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.all;
USE ieee.numeric_std.all;
USE work.systolic_package.all;

ENTITY Tensor_Processing_Unit IS
PORT(clk, reset, hard_reset, setup     : IN STD_LOGIC := '0';
     GO                                : IN STD_LOGIC := '0';
     stall                             : IN STD_LOGIC := '0';
     weights, a_in                     : IN STD_LOGIC_VECTOR(23 DOWNTO 0) := (others => '0');
	   done 						                 : OUT STD_LOGIC := '0';
     y0, y1, y2                        : OUT bus_width);
END Tensor_Processing_Unit;

ARCHITECTURE behaviour OF Tensor_Processing_Unit IS

COMPONENT WRAM IS
  PORT( aclr		: IN STD_LOGIC  := '0';
        address	: IN STD_LOGIC_VECTOR (1 DOWNTO 0);
        clock		: IN STD_LOGIC  := '1';
        data		: IN STD_LOGIC_VECTOR (23 DOWNTO 0);
        rden		: IN STD_LOGIC  := '1';
        wren		: IN STD_LOGIC;
        q		    : OUT STD_LOGIC_VECTOR (23 DOWNTO 0));
END COMPONENT;

COMPONENT URAM IS
	PORT(aclr		 : IN STD_LOGIC  := '0';
  		 address : IN STD_LOGIC_VECTOR (1 DOWNTO 0);
  		 clock	 : IN STD_LOGIC  := '1';
  		 data		 : IN STD_LOGIC_VECTOR (7 DOWNTO 0);
  		 rden		 : IN STD_LOGIC  := '1';
  		 wren		 : IN STD_LOGIC ;
  		 q		   : OUT STD_LOGIC_VECTOR (7 DOWNTO 0));
END COMPONENT;

COMPONENT MMU IS
PORT(clk, reset, hard_reset, ld, ld_w, stall  	  : IN STD_LOGIC := '0';
     a0, a1, a2                                   : IN UNSIGNED(7 DOWNTO 0) := (others => '0');
     w0, w1, w2                                   : IN UNSIGNED(7 DOWNTO 0) := (others => '0');
	   y0, y1, y2 				                          : OUT UNSIGNED(7 DOWNTO 0) := (others => '0');
     collect_matrix                               : OUT STD_LOGIC := '0');
END COMPONENT;

COMPONENT Activation_Unit IS
PORT(clk,reset, hard_reset, GO_store_matrix  : IN STD_LOGIC := '0';
     stall                                   : IN STD_LOGIC := '0';
     y_in0, y_in1, y_in2                     : IN UNSIGNED(7 DOWNTO 0) := (others => '0');
	   done 						                       : OUT STD_LOGIC := '0';
     row0, row1, row2                        : OUT bus_width);
END COMPONENT;

TYPE state_type is (idle, load_row0, load_row1, load_row2); -- setup
TYPE state_type1 is (idle1, load_row0_1, load_row1_1, load_row2_1, stall_readW1, stall_readW2); -- Go part1 (load W)
TYPE state_type2 is (idle2, load_a1, load_a2, load_a3, load_a4, load_a5, stall_readU1, stall_readU2); -- Go part2 (load U)
SIGNAL next_state, current_state                               : state_type; -- setup
SIGNAL next_state1, current_state1                             : state_type1; -- GO part1 (load W)
SIGNAL next_state2, current_state2                             : state_type2; -- GO part2 (load U)
SIGNAL any_reset, store_matrix, weight_ld, a_ld, GO_1, GO_2    : STD_LOGIC := '0';
SIGNAL W_out                                                   : STD_LOGIC_VECTOR(23 DOWNTO 0);
SIGNAL W_out0, W_out1, W_out2                                  : UNSIGNED(7 DOWNTO 0);
SIGNAL element_address0, element_address1, element_address2    : STD_LOGIC_VECTOR(1 DOWNTO 0) := (others => '0');
SIGNAL a0, a1, a2, a_in0, a_in1, a_in2                         : STD_LOGIC_VECTOR(7 DOWNTO 0) := (others => '0');
SIGNAL MMU_y0, MMU_y1, MMU_y2, a0_uns, a1_uns, a2_uns          : UNSIGNED(7 DOWNTO 0) := (others => '0');

BEGIN

  -- setup mode
  PROCESS(current_state, current_state1, current_state2, setup, GO)
  BEGIN
    IF (setup = '1') THEN -- if in setup mode go through following FSM
      CASE current_state IS
        WHEN idle =>
          element_address0 <= "01"; -- used for WRAM row and URAM
          element_address1 <= "01";
          element_address2 <= "01";
          next_state <= load_row0;

        WHEN load_row0 =>
          element_address0 <= "10";
          element_address1 <= "10";
          element_address2 <= "10";
          next_state <= load_row1;

        WHEN load_row1 =>
          element_address0 <= "11";
          element_address1 <= "11";
          element_address2 <= "11";
          next_state <= load_row2;

        -- Set all control and weight buffers to 0 for the next cycle once the FSM returns to Idle.
        WHEN load_row2 =>
          element_address0 <= "00";
          element_address1 <= "00";
          element_address2 <= "00";
          next_state <= idle;
        END CASE;

    ELSIF (GO = '1') THEN
       IF (GO_2 = '0' OR GO_1 = '1') THEN -- if at start of GO mode go through following FSM
          CASE current_state1 IS -- GO part 1 (load W)
            WHEN idle1 =>
              GO_1 <= '1'; -- assert so when GO_2 is asserted to allow FSMs to overlap this FSM will still be run through
              element_address0 <= "01"; -- addresses used for both WRAM row and URAM
              element_address1 <= "01";
              element_address2 <= "01";
              next_state1 <= load_row0_1;

            WHEN load_row0_1 =>
              element_address0 <= "10";
              element_address1 <= "10";
              element_address2 <= "10";
              next_state1 <= load_row1_1;

            WHEN load_row1_1 =>
              weight_ld <= '1'; -- assert now to start loading in values requested to be read from WRAM, considering 2 clocks needed to read from WRAM
              element_address0 <= "11";
              element_address1 <= "11";
              element_address2 <= "11";
              GO_2 <= '1'; -- assert GO_2 to hide latency of URAM when reading values
              next_state1 <= load_row2_1;

            WHEN load_row2_1 =>
              element_address0 <= "00";
              element_address1 <= "00";
              element_address2 <= "00";
              next_state1 <= stall_readW1;

              -- go through stall states to properly align reading into MMU considering it takes two clocks to read from the WRAM
              WHEN stall_readW1 =>
                next_state1 <= stall_readW2;

              WHEN stall_readW2 =>
                weight_ld <= '0'; -- turn off load as WRAM will stop outputting the values we want here
                GO_1 <= '0'; -- set GO_1 to zero so on the next run through the FSM will not be triggered
                next_state1 <= idle1;
          END CASE;
        END IF;

      IF (GO_2 = '1') THEN -- if in GO mode and W has been requested to read start following FSM
          CASE current_state2 IS -- Go part 2 (load U)
            WHEN idle2 =>
              element_address0 <= "01" ; -- element addresses cascading through states to provide 0 padding to produce accurate product
              element_address1 <= "00";
              element_address2 <= "00";
              next_state2 <= load_a1;

            WHEN load_a1 =>
              element_address0 <= "10";
              element_address1 <= "01";
              element_address2 <= "00";
              next_state2 <= load_a2;

            WHEN load_a2 =>
              a_ld <= '1';
              element_address0 <= "11";
              element_address1 <= "10";
              element_address2 <= "01";
              next_state2 <= load_a3;

            WHEN load_a3 =>
              element_address0 <= "00";
              element_address1 <= "11";
              element_address2 <= "10";
              next_state2 <= load_a4;

            WHEN load_a4 =>
              element_address0 <= "00";
              element_address1 <= "00";
              element_address2 <= "11";
              next_state2 <= load_a5;

            WHEN load_a5 =>
              element_address0 <= "00";
              element_address1 <= "00";
              element_address2 <= "00";
              next_state2 <= stall_readU1;

            -- go through stall states to properly align reading into MMU considering it takes two clocks to read from the URAM
            WHEN stall_readU1 =>
              next_state2 <= stall_readU2;

            WHEN stall_readU2 =>
              a_ld <= '0'; -- unassert as URAM will stop outputting the values we want here
              GO_2 <= '0'; -- unassert as we are done computing in the MMU!
              next_state2 <= idle2;

          END CASE;
       END IF;
    END IF;
  END PROCESS;

  -- process to control clock,  resets, and stall for all FSMs and modes
  PROCESS(clk, hard_reset, reset, stall)
    BEGIN
      -- resets take first priority, then stalls, and then normal state changes
      IF (hard_reset = '1' OR reset = '1') THEN
        IF (hard_reset = '1') THEN -- only reset when hard_reset is asserted when in setup or GO part 1 (load W) modes
          current_state <= idle;
          current_state1 <= idle1;
        END IF;
          current_state2 <= idle2;

      ELSIF (GO = '1' AND stall = '1') THEN -- only stall in GO mode, not setup mode
        current_state <= next_state;
        current_state1 <= next_state1;
        current_state2 <= next_state2;

      ELSIF (Rising_Edge(clk)) THEN -- change states only on rising edges
        current_state <= next_state;
        current_state1 <= next_state1;
        current_state2 <= next_state2;
      END IF;
  END PROCESS;

    any_reset <= (hard_reset OR reset); -- variable for when to reset URAM

    a_in0 <= STD_LOGIC_VECTOR(a_in(23 DOWNTO 16)); -- splice a_in input into and take first 8 bits
    a_in1 <= STD_LOGIC_VECTOR(a_in(15 DOWNTO 8)); -- splice a_in input into and take middle 8 bits
    a_in2 <= STD_LOGIC_VECTOR(a_in(7 DOWNTO 0)); -- splice a_in input into and take last 8 bits

    -- port map STPU inputs into WRAM and URAM
    WRAM1 : WRAM PORT MAP(aclr => hard_reset, address => element_address0, clock => clk, data => weights, rden => GO_1, wren => setup, q => W_out);

    URAM1 : URAM PORT MAP(aclr => any_reset, address => element_address0, clock => clk, data => a_in0, rden => GO_2, wren => setup, q => a0);
    URAM2 : URAM PORT MAP(aclr => any_reset, address => element_address1, clock => clk, data => a_in1, rden => GO_2, wren => setup, q => a1);
    URAM3 : URAM PORT MAP(aclr => any_reset, address => element_address2, clock => clk, data => a_in2, rden => GO_2, wren => setup, q => a2);

    -- cast outputs from URAMs, STD_LOGIC_VECTOR to UNSIGNED, to allow inputting them int MMU
    a0_uns <= UNSIGNED(a0); -- Massive bug was fixed here on 12/6/2020 by the great Laura Floodster
    a1_uns <= UNSIGNED(a1);
    a2_uns <= UNSIGNED(a2);

   -- splice output from WRAM into 3 8-bit pieces and cast from STD_LOGIC_VECTOR to UNSIGNED to allow inputting into MMU
    W_out0 <= UNSIGNED(W_out(23 DOWNTO 16));
    W_out1 <= UNSIGNED(W_out(15 DOWNTO 8));
    W_out2 <= UNSIGNED(W_out(7 DOWNTO 0));

    -- port map signals from URAM, WRAM, and overall STPU into MMU
    MMU_final : MMU PORT MAP(clk => clk, reset => reset, hard_reset => hard_reset, ld => a_ld , ld_w => weight_ld, stall => stall, a0 => a0_uns, a1 => a1_uns, a2 => a2_uns, w0 => W_out0, w1 =>  W_out1, w2 =>  W_out2, y0 => MMU_y0, y1 => MMU_y1, y2 => MMU_y2, collect_matrix => store_matrix);

    -- port map signals from MMU and overall STPU into Activation unit
    AU_final : Activation_Unit PORT MAP(clk => clk, reset => reset, hard_reset => hard_reset, GO_store_matrix => store_matrix, stall => stall, y_in0 => MMU_y0, y_in1 => MMU_y1, y_in2 => MMU_y2, done => done, row0 => y0, row1 => y1, row2 => y2 );

END behaviour;
