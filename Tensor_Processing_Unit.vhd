LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.all;
USE ieee.numeric_std.all;
USE work.systolic_package.all;

ENTITY Tensor_Processing_Unit IS
PORT(clk, reset, hard_reset, setup     : IN STD_LOGIC := '0';
     GO                                : IN STD_LOGIC := '0';
     stall                             : IN STD_LOGIC := '0';
     weights, a_in                     : IN STD_LOGIC_VECTOR(23 DOWNTO 0);
	   done 						                 : OUT STD_LOGIC := '0';
     y0, y1, y2                        : OUT bus_width);
END Tensor_Processing_Unit;

-- Will we always reset?
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
PORT(clk, reset, hard_reset, ld, ld_w, stall  	  : IN STD_LOGIC;
     a0, a1, a2                                   : IN UNSIGNED(7 DOWNTO 0);
     w0, w1, w2                                   : IN UNSIGNED(7 DOWNTO 0);
	   y0, y1, y2 				                          : OUT UNSIGNED(7 DOWNTO 0);
     collect_matrix                               : OUT STD_LOGIC);
END COMPONENT;

COMPONENT Activation_Unit IS
PORT(clk, reset, hard_reset, GO_store_matrix  : IN STD_LOGIC;
     stall                  : IN STD_LOGIC := '0';
     y_in0, y_in1, y_in2    : IN UNSIGNED(7 DOWNTO 0);
	   done 						      : OUT STD_LOGIC;
     row0, row1, row2       : OUT bus_width);
END COMPONENT;

TYPE state_type is (idle, load_row0, load_row1, load_row2); -- setup
TYPE state_type1 is (idle1, load_row0_1, load_row1_1, load_row2_1, stall_readW1, stall_readW2); -- Go part1
TYPE state_type2 is (idle2, load_a1, load_a2, load_a3, load_a4, load_a5, stall_readU1, stall_readU2); -- Go part2
SIGNAL next_state, current_state                               : state_type; -- next_state and current_state are used for the setup and go, while next_state2 and current_state2 are used fortje computation + activation at the MMU
SIGNAL next_state1, current_state1                             : state_type1;
SIGNAL next_state2, current_state2                             : state_type2;
SIGNAL any_reset, store_matrix, weight_ld, a_ld, GO_1, GO_2   : STD_LOGIC := '0';
SIGNAL W_out                                                   : STD_LOGIC_VECTOR(23 DOWNTO 0);
SIGNAL W_out0, W_out1, W_out2                                  : UNSIGNED(7 DOWNTO 0);
SIGNAL element_address0, element_address1, element_address2    : STD_LOGIC_VECTOR(1 DOWNTO 0);
SIGNAL a0, a1, a2, a_in0, a_in1, a_in2                         : STD_LOGIC_VECTOR(7 DOWNTO 0) := (others => '0');
SIGNAL MMU_y0, MMU_y1, MMU_y2, a0_uns, a1_uns, a2_uns          : UNSIGNED(7 DOWNTO 0) := (others => '0');

BEGIN

  -- setup mode
  PROCESS(current_state, current_state1, current_state2, setup, GO)
  BEGIN
    IF (setup = '1') THEN -- fail safe
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
          element_address0 <= "00"; -- ?????????????????????????
          element_address1 <= "00";
          element_address2 <= "00";
          next_state <= idle;
        END CASE;

    ELSIF (GO = '1') THEN
       IF (GO_2 = '0') THEN
          CASE current_state1 IS -- GO part 1
            WHEN idle1 =>
              GO_1 <= '1';
              element_address0 <= "01"; -- used for WRAM row and URAM
              element_address1 <= "01";
              element_address2 <= "01";
              next_state1 <= load_row0_1;

            WHEN load_row0_1 =>
              element_address0 <= "10";
              element_address1 <= "10";
              element_address2 <= "10";
              next_state1 <= load_row1_1;

            WHEN load_row1_1 =>
              weight_ld <= '1'; -- THIS HAS BEEN MOVED ;)
              element_address0 <= "11";
              element_address1 <= "11";
              element_address2 <= "11";
              next_state1 <= load_row2_1;

            -- Set all control and weight buffers to 0 for the next cycle once the FSM returns to Idle.
            WHEN load_row2_1 =>
              element_address0 <= "00"; -- ?????????????????????????
              element_address1 <= "00";
              element_address2 <= "00";
              next_state1 <= stall_readW1;

              WHEN stall_readW1 =>
                next_state1 <= stall_readW2;

              WHEN stall_readW2 =>
                weight_ld <= '0';
                GO_1 <= '0';
                GO_2 <= '1';
                next_state1 <= idle1;
          END CASE;

      ELSE -- GO_2 = '1'
          CASE current_state2 IS -- Go part 2
            WHEN idle2 =>
              element_address0 <= "01" ;
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

            WHEN stall_readU1 =>
              next_state2 <= stall_readU2;

            WHEN stall_readU2 =>
              a_ld <= '0';
              GO_2 <= '0';
              next_state2 <= idle2;

          END CASE;
       END IF;
    END IF;
  END PROCESS;

  PROCESS(clk, hard_reset, reset, stall)
    BEGIN
      IF (hard_reset = '1' OR reset = '1') THEN
        IF (hard_reset = '1') THEN
          current_state <= idle;
          current_state1 <= idle1;
        END IF;
          current_state2 <= idle2;
          done <= '0';

      ELSIF (GO = '1' AND stall = '1') THEN
        current_state <= next_state;
        current_state1 <= next_state1;
        current_state2 <= next_state2;

      ELSIF (Rising_Edge(clk)) THEN
        current_state <= next_state;
        current_state1 <= next_state1;
        current_state2 <= next_state2;
      END IF;
  END PROCESS;

    any_reset <= (hard_reset OR reset);

    a_in0 <= STD_LOGIC_VECTOR(a_in(23 DOWNTO 16));
    a_in1 <= STD_LOGIC_VECTOR(a_in(15 DOWNTO 8));
    a_in2 <= STD_LOGIC_VECTOR(a_in(7 DOWNTO 0));

    WRAM1 : WRAM PORT MAP(aclr => hard_reset, address => element_address0, clock => clk, data => weights, rden => GO_1, wren => setup, q => W_out);

    URAM1 : URAM PORT MAP(aclr => any_reset, address => element_address0, clock => clk, data => a_in0, rden => GO_2, wren => setup, q => a0);
    URAM2 : URAM PORT MAP(aclr => any_reset, address => element_address1, clock => clk, data => a_in1, rden => GO_2, wren => setup, q => a1);
    URAM3 : URAM PORT MAP(aclr => any_reset, address => element_address2, clock => clk, data => a_in2, rden => GO_2, wren => setup, q => a2);

    a0_uns <= UNSIGNED(a0);
    a1_uns <= UNSIGNED(a0);
    a2_uns <= UNSIGNED(a0);

    W_out0 <= UNSIGNED(W_out(23 DOWNTO 16));
    W_out1 <= UNSIGNED(W_out(15 DOWNTO 8));
    W_out2 <= UNSIGNED(W_out(7 DOWNTO 0));

    MMU_final : MMU PORT MAP(clk => clk, reset => reset, hard_reset => hard_reset, ld => a_ld , ld_w => weight_ld, stall => stall, a0 => a0_uns, a1 => a1_uns, a2 => a2_uns, w0 => W_out0, w1 =>  W_out1, w2 =>  W_out2, y0 => MMU_y0, y1 => MMU_y1, y2 => MMU_y2, collect_matrix => store_matrix);

    AU_final : Activation_Unit PORT MAP(clk => clk, reset => reset, hard_reset => hard_reset, GO_store_matrix => store_matrix, stall => stall, y_in0 => MMU_y0, y_in1 => MMU_y1, y_in2 => MMU_y2, done => done, row0 => y0, row1 => y1, row2 => y2 );


END behaviour;
