//copyright Cheat Engine 2022. All rights reserved
unit disassemblerarm64;

{$mode objfpc}{$H+}
{$WARN 3177 off : Some fields coming after "$1" were not initialized}
interface

uses
  Classes, SysUtils, LastDisassembleData;

type
  
  TInstructionGroupPointerType=(igpGroup, igpInstructions);
  TInstructionGroup=record
    mask: DWORD;
    value: DWORD;
    list: pointer;
    listType: TInstructionGroupPointerType;
  end;
  TInstructionGroupArray=array of TInstructionGroup;
  PInstructionGroupArray=^TInstructionGroupArray;


  TIndexedParameter=(ind_no, ind_index, ind_stop, ind_stopexp, ind_single, ind_singleexp);
  TArm64ParameterType=(pt_reglist_vector, pt_reglist_vector_specificsize,
    pt_reglist_vectorsingle, pt_prfop, pt_sysop_at, pt_sysop_dc, pt_sysop_ic,
    pt_sysop_tlbi, pt_pstatefield_SP, pt_pstatefield_DAIFSet,
    pt_pstatefield_DAIFClr, pt_barrierOption, pt_systemreg, pt_creg, pt_xreg,
    pt_wreg, pt_wreg2x, pt_xreg2x, pt_breg, pt_hreg, pt_sreg, pt_dreg, pt_qreg, pt_sdreg, pt_hsreg,
    pt_imm, pt_xminimm,pt_immminx, pt_imm2, pt_imm2_8, pt_imm32or64, pt_imm_bitmask, pt_imm_1shlval, pt_imm_val0_0, pt_imm_val0, pt_imm_val1,
    pt_imm_val2, pt_imm_val4, pt_imm_val8, pt_imm_mul4, pt_imm_mul8,
    pt_imm_mul16, pt_simm, pt_pimm, pt_fpimm8,pt_scale, pt_label, pt_addrlabel,
    pt_indexwidthspecifier, pt_extend_amount, pt_extend_amount_Extended_Register,
    pt_lslSpecific, pt_mslSpecific, pt_lsl0or12, pt_lsldiv16, pt_shift16, pt_cond, pt_vreg_8B, pt_vreg_16B,
    pt_vreg_4H, pt_vreg_8H, pt_vreg_2S, pt_vreg_4S, pt_vreg_2D, pt_vreg_B_1bit,
    pt_vreg_T, pt_vreg_T2, pt_vreg_T2_AssumeQ1, pt_vreg_T_sizenot3,pt_vreg_T_sizenot3or0, pt_vreg_SD_2bit, pt_vreg_B_Index, pt_vreg_H_Index, pt_vreg_S_Index, pt_vreg_D_Index, pt_vreg_D_Index1,
    pt_vreg_H_HLMIndex, pt_vreg_S_HLIndex, pt_vreg_HS_HLMIndex, pt_vreg_SD_HLIndex, pt_vreg_D_HIndex
    );



  TAParameters=record
    ptype: TArm64ParameterType;
    offset: dword; //binary position  (in case of imm2/pt_reglist_*: offset is a 32-bit bitmask and assumed concatenated from left to right)
    maxval: dword;
    extra:  qword; //extra data for paramtypes
    optional: boolean;
    defvalue: integer; //in case of optional
    index: TIndexedParameter;
  end;

  TAParametersList=array of TAParameters;

  TInstructionUse=(iuBoth=0, iuAssembler=1, iuDisassembler=2);

  POpcodeArray=^topcodearray;
  TOpcode=record
    mnemonic: string;
    params: TAParametersList;
    mask: DWORD;
    value:DWORD;
    use: TInstructionUse;
    alt: popcodearray;
  end;
  POpcode=^TOpcode;
  TOpcodeArray=array of TOpcode;


  TArm64Disassembler=object
  private
    address: qword;
    opcode: uint32;

    function GetIMM2Value(mask: dword): dword;
    function GetIMM2_8Value(mask: dword): qword;
    function ParseParameters(plist: TAParametersList): boolean;
    function ScanOpcodeList(const list: topcodearray): boolean;
    function ScanGroupList(const list: TInstructionGroupArray): boolean;
  public
    LastDisassembleData: TLastDisassembleData;
    function disassemble(var DisassembleAddress: ptruint{$ifdef armdev}; _opcode: dword{$endif}): string;
  end;

  {$ifdef armdev}
  procedure GetArmInstructionsAssemblerListDebug(r: tstrings);
  {$endif}

  procedure InitARM64Support;

implementation

{$ifndef armdev}
uses NewKernelHandler,ProcessHandlerUnit,StringHashList;
{$else}
uses StringHashList, math;
{$endif}



const
  ArmConditions: array [0..15] of string=('EQ','NE','CS', 'CC', 'MI', 'PL', 'VS', 'VC', 'HI', 'LS', 'GE', 'LT', 'GT', 'LE', 'AL','NV');
  ArmRegistersNoName32 : array [0..31] of string=('W0','W1','W2','W3','W4','W5','W6','W7','W8','W9','W10','W11','W12','W13','W14','W15','W16','W17','W18','W19','W20','W21','W22','W23','W24','W25','W26','W27','W28','W29','W30','W31');
  ArmRegistersNoName : array [0..31] of string=('X0','X1','X2','X3','X4','X5','X6','X7','X8','X9','X10','X11','X12','X13','X14','X15','X16','X17','X18','X19','X20','X21','X22','X23','X24','X25','X26','X27','X28','X29','X30','X31');

//  ArmInstructionsBase: array [0..6] of  ...
//    0:ArmInstructionsUnused [0..0]
//    1:ArmInstructionsSystem: ...
//    2:ArmInstructionsDataProcessing: ...

//example:
//191c: 4a c9 46 f9   ldr     x10, [x10, #3472]
//f946c94a=11111001010001101100100101001010  = Load/store register (unsigned immediate)   , unsigned offset variant
//LDR <Xt>, [<Xn|SP>{, #<pimm>}]

//

  ArmInstructionsCompareAndBranch: array of TOpcode= (
    (mnemonic:'CBZ'; params:((ptype:pt_wreg),(ptype:pt_label; offset:5; maxval: $7ffff )); mask:%11111111000000000000000000000000; value: %00110100000000000000000000000000),
    (mnemonic:'CBZ'; params:((ptype:pt_xreg),(ptype:pt_label; offset:5; maxval: $7ffff));  mask:%11111111000000000000000000000000; value: %10110100000000000000000000000000),
    (mnemonic:'CBNZ'; params:((ptype:pt_wreg),(ptype:pt_label; offset:5; maxval: $7ffff)); mask:%11111111000000000000000000000000; value: %00110101000000000000000000000000),
    (mnemonic:'CBNZ'; params:((ptype:pt_xreg),(ptype:pt_label; offset:5; maxval: $7ffff)); mask:%11111111000000000000000000000000; value: %10110101000000000000000000000000)
  );

  ArmInstructionsTestAndBranchImm: array of TOpcode= (
    (mnemonic:'TBZ';  params:((ptype:pt_xreg),(ptype:pt_imm2; offset:%10000000111110000000000000000000),(ptype:pt_label; offset:5; maxval: $3FFF)); mask:%11111111000000000000000000000000; value: %10110110000000000000000000000000),
    (mnemonic:'TBZ';  params:((ptype:pt_wreg),(ptype:pt_imm2; offset:%10000000111110000000000000000000),(ptype:pt_label; offset:5; maxval: $3FFF)); mask:%11111111000000000000000000000000; value: %00110110000000000000000000000000),
    (mnemonic:'TBNZ'; params:((ptype:pt_xreg),(ptype:pt_imm2; offset:%10000000111110000000000000000000),(ptype:pt_label; offset:5; maxval: $3FFF)); mask:%11111111000000000000000000000000; value: %10110111000000000000000000000000),
    (mnemonic:'TBNZ'; params:((ptype:pt_wreg),(ptype:pt_imm2; offset:%10000000111110000000000000000000),(ptype:pt_label; offset:5; maxval: $3FFF)); mask:%11111111000000000000000000000000; value: %00110111000000000000000000000000)

  );

  ArmInstructionsUnconditionalBranchImm: array of TOpcode= (
    (mnemonic:'B';  params:((ptype:pt_label; offset:0; maxval: $7FFFFFF )); mask:%11111100000000000000000000000000; value: %00010100000000000000000000000000),
    (mnemonic:'BL'; params:((ptype:pt_label; offset:0; maxval: $7FFFFFF )); mask:%11111100000000000000000000000000; value: %10010100000000000000000000000000)
  );


  ArmInstructionsConditionalBranchImm: array of TOpcode= (
    (mnemonic:'B.EQ';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000000),
    (mnemonic:'B.NE';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000001),
    (mnemonic:'B.CS';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000010),
    (mnemonic:'B.CC';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000011),
    (mnemonic:'B.MI';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000100),
    (mnemonic:'B.PL';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000101),
    (mnemonic:'B.VS';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000110),
    (mnemonic:'B.VC';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000000111),
    (mnemonic:'B.HI';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001000),
    (mnemonic:'B.LS';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001001),
    (mnemonic:'B.GE';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001010),
    (mnemonic:'B.LT';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001011),
    (mnemonic:'B.GT';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001100),
    (mnemonic:'B.LE';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001101),
    (mnemonic:'B.AL';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001110),
    (mnemonic:'B.NV';  params:((ptype:pt_label; offset:5; maxval: $7FFFF )); mask:%11111111000000000000000000010000; value: %01010100000000000000000000001111)
  );

  ArmInstructionsUnconditionalBranchReg: array of TOpcode= (
     (mnemonic:'BR';  params:((ptype:pt_xreg; offset:5)); mask:%11111111111111111111110000011111; value: %11010110000111110000000000000000),
     (mnemonic:'BLR';  params:((ptype:pt_xreg; offset:5)); mask:%11111111111111111111110000011111; value: %11010110001111110000000000000000),
     (mnemonic:'RET';  params:((ptype:pt_xreg; offset:5; maxval:31; extra: 0; optional:true; defvalue:30)); mask:%11111111111111111111110000011111; value: %11010110010111110000000000000000),
     (mnemonic:'ERET';  params:(); mask:%11111111111111111111111111111111; value: %11010110100111110000001111100000),
     (mnemonic:'DRPS';  params:(); mask:%11111111111111111111111111111111; value: %11010110101111110000001111100000)
  );

  ArmInstructionsExceptionGen: array of TOpcode= (
    (mnemonic:'SVC'; params:((ptype:pt_imm; offset:5; maxval: 65535)); mask:%11111111111000000000000000011111; value:%11010100000000000000000000000001),
    (mnemonic:'HVC'; params:((ptype:pt_imm; offset:5; maxval: 65535)); mask:%11111111111000000000000000011111; value:%11010100000000000000000000000010),
    (mnemonic:'SMC'; params:((ptype:pt_imm; offset:5; maxval: 65535)); mask:%11111111111000000000000000011111; value:%11010100000000000000000000000011),
    (mnemonic:'BRK'; params:((ptype:pt_imm; offset:5; maxval: 65535)); mask:%11111111111000000000000000011111; value:%11010100001000000000000000000000),
    (mnemonic:'HLT'; params:((ptype:pt_imm; offset:5; maxval: 65535)); mask:%11111111111000000000000000011111; value:%11010100010000000000000000000000),
    (mnemonic:'DCPS1'; params:((ptype:pt_imm; offset:5; maxval: 65535; extra: 0;optional: true; defvalue:0)); mask:%11111111111000000000000000011111; value:%11010100101000000000000000000001),
    (mnemonic:'DCPS2'; params:((ptype:pt_imm; offset:5; maxval: 65535; extra: 0;optional: true; defvalue:0)); mask:%11111111111000000000000000011111; value:%11010100101000000000000000000010),
    (mnemonic:'DCPS3'; params:((ptype:pt_imm; offset:5; maxval: 65535; extra: 0;optional: true; defvalue:0)); mask:%11111111111000000000000000011111; value:%11010100101000000000000000000011)

  );

  ArmInstructionsSYS_ALTS: array of topcode= (
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111100000000000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011000111100000000000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011100111100000000000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111100000100000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011000111100000100000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011100111100000100000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111100001000000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111100001100000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011000111100010000000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011000111100010100000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011000111100011000000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011000111100011100000; use: iuDisassembler),
    (mnemonic:'AT';      params:((ptype:pt_sysop_at;offset:5),(ptype:pt_xreg)); mask:%11111111111110000000000000000000; value:%11010101000010000000000000000000; use: iuAssembler),


    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010110111010000100000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111011000100000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111011001000000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010110111101000100000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111101001000000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010110111101100100000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010110111111000100000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111111001000000; use: iuDisassembler),
    (mnemonic:'DC';      params:((ptype:pt_sysop_dc;offset:5),(ptype:pt_xreg)); mask:%11111111111110000000000000000000; value:%11010101000010000000000000000000; use: iuAssembler),

    (mnemonic:'IC';      params:((ptype:pt_sysop_ic;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111000100000000; use: iuDisassembler),
    (mnemonic:'IC';      params:((ptype:pt_sysop_ic;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010000111010100000000; use: iuDisassembler),
    (mnemonic:'IC';      params:((ptype:pt_sysop_ic;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010110111010100100000; use: iuDisassembler),
    (mnemonic:'IC';      params:((ptype:pt_sysop_ic;offset:5),(ptype:pt_xreg)); mask:%11111111111110000000000000000000; value:%11010101000010000000000000000000; use: iuAssembler),

    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000000000100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000000010100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000001100000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000001100000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011101000001100000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000001100100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000001100100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011101000001100100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000001101000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000001101100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000001110000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000001110100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000001110100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011101000001110100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000001111000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000001111100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000010010100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000011100000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000011100000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011101000011100000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000011100100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000011100100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011101000011100100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000011101000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000011101100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000011110000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000011110100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000011110100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011101000011110100000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000011001000011111000000; use: iuDisassembler),
    (mnemonic:'TLBI';    params:((ptype:pt_sysop_tlbi;offset:5),(ptype:pt_xreg)); mask:%11111111111111111111111111100000; value:%11010101000010001000011111100000; use: iuDisassembler)

    );

  ArmInstructionsSystem: array of TOpcode= (
   (mnemonic:'MSR'{_imm}; params:((ptype:pt_pstatefield_SP),(ptype:pt_imm; offset:8; maxval:15)); mask:%11111111111111111111000011111111; value:%11010101000000000100000010111111),
   (mnemonic:'MSR'{_imm}; params:((ptype:pt_pstatefield_DAIFSet),(ptype:pt_imm; offset:8; maxval:15)); mask:%11111111111111111111000011111111;
                                                                                                      value:%11010101000000110100000011011111),

   (mnemonic:'MSR'{_imm}; params:((ptype:pt_pstatefield_DAIFClr),(ptype:pt_imm; offset:8; maxval:15)); mask:%11111111111111111111000011111111;
                                                                                                      value:%11010101000000110100000011111111),



   (mnemonic:'NOP';     params:(); mask:%11111111111111111111111111111111; value:%11010101000000110010000000011111 ),
   (mnemonic:'YIELD';   params:(); mask:%11111111111111111111111111111111; value:%11010101000000110010000000111111 ),
   (mnemonic:'WFE';     params:(); mask:%11111111111111111111111111111111; value:%11010101000000110010000001011111 ),
   (mnemonic:'WFI';     params:(); mask:%11111111111111111111111111111111; value:%11010101000000110010000001111111 ),
   (mnemonic:'SEV';     params:(); mask:%11111111111111111111111111111111; value:%11010101000000110010000010011111 ),
   (mnemonic:'SEVL';    params:(); mask:%11111111111111111111111111111111; value:%11010101000000110010000010111111 ),
   (mnemonic:'HINT';    params:((ptype:pt_imm;offset:5;maxval:127)); mask:%11111111111111111111000000011111; value:%11010101000000110010000000011111),

   (mnemonic:'CLREX';   params:((ptype:pt_imm;offset:8;maxval:15; extra: 0; optional:true; defvalue:15)); mask:%11111111111111111111000011111111; value:%11010101000000110011000001011111),

   (mnemonic:'DSB';     params:((ptype:pt_barrierOption;offset:4;maxval:15)); mask:%11111111111111111111000011111111; value:%11010101000000110011000010011111),
   (mnemonic:'DMB';     params:((ptype:pt_barrierOption;offset:4;maxval:15)); mask:%11111111111111111111000011111111; value:%11010101000000110011000010111111),
   (mnemonic:'ISB';     params:((ptype:pt_barrierOption;offset:4;maxval:15; extra: 0; optional:true; defvalue:15)); mask:%11111111111111111111000011111111; value:%11010101000000110011000011011111),


   (mnemonic:'SYS';     params:((ptype:pt_imm;offset:16;maxval:7), (ptype:pt_creg; offset:12), (ptype:pt_creg; offset:8), (ptype:pt_imm;offset:5;maxval:7), (ptype:pt_xreg; offset:0; maxval:31; extra: 0; optional: true; defvalue:31)); mask:%11111111111110000000000000000000; value:%11010101000010000000000000000000 ; use:iuBoth; alt: @ArmInstructionsSYS_ALTS),
   (mnemonic:'MSR'{_reg};params:((ptype:pt_systemreg; offset:5),(ptype:pt_xreg; offset:0)); mask:%11111111111110000000000000000000; value:%11010101000100000000000000000000),
   (mnemonic:'SYSL';    params:((ptype:pt_imm;offset:16;maxval:7), (ptype:pt_creg; offset:12), (ptype:pt_creg; offset:8), (ptype:pt_imm;offset:5;maxval:7), (ptype:pt_xreg; offset:0; maxval:31; extra: 0; optional: true; defvalue:31)); mask:%11111111111110000000000000000000; value:%11010101001010000000000000000000),
   (mnemonic:'MRS';     params:((ptype:pt_xreg; offset:0), (ptype:pt_systemreg; offset:5)); mask:%11111111111110000000000000000000; value:%11010101001100000000000000000000)
  );

  ArmInstructionsUNALLOCATED : array of TOpcode=(
    (mnemonic:'UNALLOCATED'; params:(); mask:%00011000000000000000000000000000; value:%00000000000000000000000000000000)
  );

  ArmInstructionsLoadStoreExlusive: array of TOpcode=(
    (mnemonic:'STXRB';  params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %00001000000000000111110000000000),
    (mnemonic:'STLXRB'; params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %00001000000000001111110000000000),
    (mnemonic:'LDXRB';  params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %00001000010111110111110000000000),
    (mnemonic:'LDAXRB'; params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %00001000010111111111110000000000),
    (mnemonic:'STLRB';  params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %00001000100111111111110000000000),
    (mnemonic:'LDARB';  params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %00001000110111111111110000000000),
    (mnemonic:'STXRH';  params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %01001000000000000111110000000000),
    (mnemonic:'STLXRH'; params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %01001000000000001111110000000000),
    (mnemonic:'LDXRH';  params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %01001000010111110111110000000000),
    (mnemonic:'LDAXRH'; params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %01001000010111111111110000000000),
    (mnemonic:'STLRH';  params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %01001000100111111111110000000000),
    (mnemonic:'LDARH';  params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %01001000110111111111110000000000),
    (mnemonic:'STXR';   params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %10001000000000000111110000000000),
    (mnemonic:'STLXR';  params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %10001000000000001111110000000000),
    (mnemonic:'STXP';   params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_wreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001000000000000000; value: %10001000001000000000000000000000),
    (mnemonic:'STLXP';  params:((ptype:pt_wreg; offset: 16),(ptype: pt_wreg; offset: 0), (ptype: pt_wreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001000000000000000; value: %10001000001000001000000000000000),
    (mnemonic:'LDXR';   params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %10001000010111110111110000000000),
    (mnemonic:'LDAXR';  params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %10001000010111111111110000000000),
    (mnemonic:'LDXP';   params:((ptype:pt_wreg; offset: 0),(ptype: pt_wreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111000000000000000; value: %10001000011111110000000000000000),
    (mnemonic:'LDAXP';  params:((ptype:pt_wreg; offset: 0),(ptype: pt_wreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111000000000000000; value: %10001000011111111000000000000000),
    (mnemonic:'STLR';   params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %10001000100111111111110000000000),
    (mnemonic:'LDAR';   params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %10001000110111111111110000000000),
    (mnemonic:'STXR';   params:((ptype:pt_wreg; offset: 16),(ptype: pt_xreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %11001000000000000111110000000000),
    (mnemonic:'STLXR';  params:((ptype:pt_wreg; offset: 16),(ptype: pt_xreg; offset: 0), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001111110000000000; value: %11001000000000001111110000000000),
    (mnemonic:'STXP';   params:((ptype:pt_wreg; offset: 16),(ptype: pt_xreg; offset: 0), (ptype: pt_xreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001000000000000000; value: %11001000001000000000000000000000),
    (mnemonic:'STLXP';  params:((ptype:pt_wreg; offset: 16),(ptype: pt_xreg; offset: 0), (ptype: pt_xreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111000001000000000000000; value: %11001000001000001000000000000000),
    (mnemonic:'LDXR';   params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %11001000010111110111110000000000),
    (mnemonic:'LDAXR';  params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %11001000010111111111110000000000),
    (mnemonic:'LDXP';   params:((ptype:pt_wreg; offset: 0),(ptype: pt_xreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111000000000000000; value: %11001000011111110000000000000000),
    (mnemonic:'LDAXP';  params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:10), (ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111000000000000000; value: %11001000011111111000000000000000),
    (mnemonic:'STLR';   params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %11001000100111111111110000000000),
    (mnemonic:'LDAR';   params:((ptype:pt_xreg; offset: 0),(ptype: pt_xreg; offset:5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index)); mask:%11111111111111111111110000000000; value: %11001000110111111111110000000000)
  );
  ArmInstructionsLoadRegisterLiteral: array of TOpcode=(
    (mnemonic:'LDR'; params:((ptype:pt_wreg; offset: 0),(ptype: pt_label; offset: 19; maxval:$7ffff)); mask:%11111111000000000000000000000000; value: %00011000000000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_sreg; offset: 0),(ptype: pt_label; offset: 19; maxval:$7ffff)); mask:%11111111000000000000000000000000; value: %00011100000000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_xreg; offset: 0),(ptype: pt_label; offset: 19; maxval:$7ffff)); mask:%11111111000000000000000000000000; value: %01011000000000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_dreg; offset: 0),(ptype: pt_label; offset: 19; maxval:$7ffff)); mask:%11111111000000000000000000000000; value: %01011100000000000000000000000000),
    (mnemonic:'LDRSW'; params:((ptype:pt_xreg; offset: 0),(ptype: pt_label; offset: 19; maxval:$7ffff)); mask:%11111111000000000000000000000000; value: %10011000000000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_qreg; offset: 0),(ptype: pt_label; offset: 19; maxval:$7ffff)); mask:%11111111000000000000000000000000; value: %10011100000000000000000000000000),
    (mnemonic:'PRFM'; params:((ptype:pt_prfop; offset: 0),(ptype: pt_label; offset: 19; maxval:$7ffff)); mask:%11111111000000000000000000000000; value: %11011000000000000000000000000000)
  );
  ArmInstructionsLoadStoreNoAllocatePairOffset: array of TOpcode=(
    (mnemonic:'STNP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101000000000000000000000000000),
    (mnemonic:'STNP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101000000000000000000000000000),
    (mnemonic:'STNP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101100000000000000000000000000),
    (mnemonic:'STNP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %01101100000000000000000000000000),
    (mnemonic:'STNP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101100000000000000000000000000),

    (mnemonic:'LDNP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101000010000000000000000000000),
    (mnemonic:'LDNP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101000010000000000000000000000),
    (mnemonic:'LDNP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101100010000000000000000000000),
    (mnemonic:'LDNP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %01101100010000000000000000000000),
    (mnemonic:'LDNP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101100010000000000000000000000)

  );

  ArmInstructionsLoadStoreRegisterPairPostIndexed: array of TOpcode=(
    (mnemonic:'STP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %00101000100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %10101000100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %00101100100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %01101100100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %10101100100000000000000000000000),

    (mnemonic:'LDP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %00101000110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %10101000110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %00101100110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %01101100110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000; value: %10101100110000000000000000000000),

    (mnemonic:'LDPSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0)); mask: %11111111110000000000000000000000;value:%01101000110000000000000000000000)

  );
  ArmInstructionsLoadStoreRegisterPairOffset: array of TOpcode=(
    (mnemonic:'STP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101001000000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101001000000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101101000000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %01101101000000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101101000000000000000000000000),

    (mnemonic:'LDP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101001010000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101001010000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %00101101010000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %01101101010000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %10101101010000000000000000000000),

    (mnemonic:'LDPSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000;value:%01101001010000000000000000000000)

  );
  ArmInstructionsLoadStoreRegisterPairPreIndexed: array of TOpcode=(
    (mnemonic:'STP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %00101001100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %10101001100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %00101101100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %01101101100000000000000000000000),
    (mnemonic:'STP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %10101101100000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %00101001110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %10101001110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul4;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %00101101110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul8;  offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %01101101110000000000000000000000),
    (mnemonic:'LDP'; params:((ptype:pt_qreg; offset:0),(ptype:pt_qreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_stopexp)); mask: %11111111110000000000000000000000; value: %10101101110000000000000000000000),
    (mnemonic:'LDPSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:10),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_imm_mul16; offset: 15; maxval:$7f; extra:0; optional:true; defvalue:0; index: ind_index)); mask: %11111111110000000000000000000000; value: %01101001110000000000000000000000)
  );

  ArmInstructionsLoadStoreRegisterUnscaledImmediate: array of TOpcode=(
    (mnemonic:'STURB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000000000000000000000000000),
    (mnemonic:'STURH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111000000000000000000000000000),

    (mnemonic:'LDURB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000010000000000000000000000),
    (mnemonic:'LDURH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111000010000000000000000000000),

    (mnemonic:'LDURSB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000110000000000000000000000),
    (mnemonic:'LDURSB'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000100000000000000000000000),
    (mnemonic:'LDURSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111000100000000000000000000000),

    (mnemonic:'STUR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111000000000000000000000000000),
    (mnemonic:'STUR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111000000000000000000000000000),
    (mnemonic:'STUR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100000000000000000000000000),
    (mnemonic:'STUR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111100000000000000000000000000),
    (mnemonic:'STUR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111100000000000000000000000000),
    (mnemonic:'STUR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111100000000000000000000000000),
    (mnemonic:'STUR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100100000000000000000000000),
    (mnemonic:'LDUR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111000010000000000000000000000),
    (mnemonic:'LDUR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111000010000000000000000000000),
    (mnemonic:'LDUR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100010000000000000000000000),
    (mnemonic:'LDUR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111100010000000000000000000000),
    (mnemonic:'LDUR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111100010000000000000000000000),
    (mnemonic:'LDUR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111100010000000000000000000000),
    (mnemonic:'LDUR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100110000000000000000000000),

    (mnemonic:'PRFUM'; params:((ptype:pt_prfop; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111000100000000000000000000000)

  );

  ArmInstructionsLoadStoreRegisterImmediatePostIndexed: array of TOpcode=(
    (mnemonic:'STRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000000000000000010000000000),
    (mnemonic:'STRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111000000000000000010000000000),
    (mnemonic:'LDRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000010000000000010000000000),
    (mnemonic:'LDRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111000010000000000010000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000110000000000010000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111000100000000000010000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111000110000000000010000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111000100000000000010000000000),
    (mnemonic:'LDRSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111000100000000000010000000000),
    (mnemonic:'STR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111000000000000000010000000000),
    (mnemonic:'STR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111000000000000000010000000000),
    (mnemonic:'STR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100000000000000010000000000),
    (mnemonic:'STR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111100000000000000010000000000),
    (mnemonic:'STR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111100000000000000010000000000),
    (mnemonic:'STR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111100000000000000010000000000),
    (mnemonic:'STR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100100000000000010000000000),
    (mnemonic:'LDR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111000010000000000010000000000),
    (mnemonic:'LDR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111000010000000000010000000000),
    (mnemonic:'LDR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100010000000000010000000000),
    (mnemonic:'LDR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %01111100010000000000010000000000),
    (mnemonic:'LDR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %10111100010000000000010000000000),
    (mnemonic:'LDR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %11111100010000000000010000000000),
    (mnemonic:'LDR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff)); mask: %11111111111000000000110000000000; value: %00111100110000000000010000000000)

  );
  ArmInstructionsLoadStoreRegisterUnprivileged: array of TOpcode=(
    (mnemonic:'STTRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %00111000000000000000100000000000),
    (mnemonic:'STTRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %01111000000000000000100000000000),


    (mnemonic:'LDTRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %00111000010000000000100000000000),
    (mnemonic:'LDTRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %01111000010000000000100000000000),

    (mnemonic:'LDTRSB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %00111000110000000000100000000000),
    (mnemonic:'LDTRSB'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %00111000100000000000100000000000),

    (mnemonic:'LDTRSH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %01111000110000000000100000000000),
    (mnemonic:'LDTRSH'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %01111000100000000000100000000000),

    (mnemonic:'STTR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %10111000000000000000100000000000),
    (mnemonic:'STTR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %11111000000000000000100000000000),

    (mnemonic:'LDTR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %10111000010000000000100000000000),
    (mnemonic:'LDTR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %11111000010000000000100000000000),

    (mnemonic:'LDTRSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_index),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111111000000000110000000000; value: %10111000100000000000100000000000)

  );


  ArmInstructionsLoadStoreRegisterImmediatePreIndexed: array of TOpcode=(
    (mnemonic:'STRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111000000000000000110000000000),
    (mnemonic:'STRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %01111000000000000000110000000000),
    (mnemonic:'LDRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111000010000000000110000000000),
    (mnemonic:'LDRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %01111000010000000000110000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111000110000000000110000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111000100000000000110000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %01111000110000000000110000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %01111000100000000000110000000000),
    (mnemonic:'LDRSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %10111000100000000000110000000000),
    (mnemonic:'STR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %10111000000000000000110000000000),
    (mnemonic:'STR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %11111000000000000000110000000000),
    (mnemonic:'STR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111100000000000000110000000000),
    (mnemonic:'STR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %01111100000000000000110000000000),
    (mnemonic:'STR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %10111100000000000000110000000000),
    (mnemonic:'STR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %11111100000000000000110000000000),
    (mnemonic:'STR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111100100000000000110000000000),
    (mnemonic:'LDR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %10111000010000000000110000000000),
    (mnemonic:'LDR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %11111000010000000000110000000000),
    (mnemonic:'LDR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111100010000000000110000000000),
    (mnemonic:'LDR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %01111100010000000000110000000000),
    (mnemonic:'LDR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %10111100010000000000110000000000),
    (mnemonic:'LDR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %11111100010000000000110000000000),
    (mnemonic:'LDR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_simm; offset: 12; maxval:$1ff; extra:0; optional:false; defvalue:0; index: ind_stopexp)); mask: %11111111111000000000110000000000; value: %00111100110000000000110000000000)

  );
  ArmInstructionsLoadStoreRegisterRegisterOffset: array of TOpcode=(
    (mnemonic:'STRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:0; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value: %10111000001000000000100000000000),
    (mnemonic:'LDRB'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:0; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value: %11111000011000000000100000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:0; extra:12; optional:false; defvalue:0; index: ind_index )); mask:%11111111111000000000110000000000; value: %00111000111000000000100000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:0; extra:12; optional:false; defvalue:0; index: ind_index )); mask:%11111111111000000000110000000000; value: %00111000101000000000100000000000),

    (mnemonic:'STR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:2; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %10111000001000000000100000000000),
    (mnemonic:'STR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:3; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %10111000001000000000100000000000),
    (mnemonic:'STR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:0; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %00111100001000000000100000000000),
    (mnemonic:'STR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:1; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %01111100001000000000100000000000),
    (mnemonic:'STR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:2; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %10111100001000000000100000000000),
    (mnemonic:'STR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:3; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %11111100001000000000100000000000),
    (mnemonic:'STR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:4; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %00111100101000000000100000000000),

    (mnemonic:'LDR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:2; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %10111000011000000000100000000000),
    (mnemonic:'LDR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:3; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %10111000011000000000100000000000),
    (mnemonic:'LDR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:0; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %00111100011000000000100000000000),
    (mnemonic:'LDR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:1; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %01111100011000000000100000000000),
    (mnemonic:'LDR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:2; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %10111100011000000000100000000000),
    (mnemonic:'LDR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:3; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %11111100011000000000100000000000),
    (mnemonic:'LDR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:4; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:  %00111100111000000000100000000000),

    (mnemonic:'STRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:1; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value: %01111000001000000000100000000000),
    (mnemonic:'LDRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:1; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value: %01111000011000000000100000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:1; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:%01111000111000000000100000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:1; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:%01111000101000000000100000000000),

    (mnemonic:'LDRSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:2; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:%10111000101000000000100000000000),
    (mnemonic:'PRFM'; params:((ptype:pt_prfop; offset:0),(ptype:pt_xreg; offset: 5; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16; optional:false; defvalue:0; index: ind_index ), (ptype:pt_extend_amount; offset:13; maxval:2; extra:12; optional:false; defvalue:0; index: ind_index )); mask: %11111111111000000000110000000000; value:%11111000101000000000100000000000)

  );

  ArmInstructionsLoadStoreRegisterUnsignedImmediate: array of TOpcode=(
    (mnemonic:'STRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111110000000000000000000000; value: %00111001000000000000000000000000),
    (mnemonic:'STRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111110000000000000000000000; value: %01111001000000000000000000000000),
    (mnemonic:'LDRB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111110000000000000000000000; value: %00111001010000000000000000000000),
    (mnemonic:'LDRH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask: %11111111110000000000000000000000; value: %01111001010000000000000000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:%11111111110000000000000000000000; value: %00111001110000000000000000000000),
    (mnemonic:'LDRSB'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:%11111111110000000000000000000000; value: %00111001100000000000000000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:%11111111110000000000000000000000; value: %01111001110000000000000000000000),
    (mnemonic:'LDRSH'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:%11111111110000000000000000000000; value: %01111001100000000000000000000000),
    (mnemonic:'LDRSW'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:%11111111110000000000000000000000; value: %10111001100000000000000000000000),
    (mnemonic:'STR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %10111001000000000000000000000000),
    (mnemonic:'STR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %11111001000000000000000000000000),
    (mnemonic:'STR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %00111101000000000000000000000000),
    (mnemonic:'STR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %01111101000000000000000000000000),
    (mnemonic:'STR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %10111101000000000000000000000000),
    (mnemonic:'STR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %11111101000000000000000000000000),
    (mnemonic:'STR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %00111101100000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_wreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %10111001010000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %11111001010000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_breg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %00111101010000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_hreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %01111101010000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_sreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %10111101010000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_dreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %11111101010000000000000000000000),
    (mnemonic:'LDR'; params:((ptype:pt_qreg; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:  %11111111110000000000000000000000; value: %00111101110000000000000000000000),
    (mnemonic:'PRFM'; params:((ptype:pt_prfop; offset:0),(ptype:pt_xreg; offset: 5; maxval:31; extra:0; optional:false; defvalue:0; index: ind_single),(ptype:pt_pimm; offset: 12; maxval:$fff; extra:0; optional:false; defvalue:0; index: ind_stop)); mask:%11111111110000000000000000000000; value: %11111001100000000000000000000000)

  );


  ArmInstructionsAdvSIMDLoadStoreMultipleStructures: array of TOpcode=(
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100000000000111000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100000000001010000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100000000000110000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100000000000010000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100000000001000000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100000000000100000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100000000000000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100010000000111000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100010000001010000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100010000000110000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100010000000010000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100010000001000000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100010000000100000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001100010000000000000000000000)
  );
  ArmInstructionsAdvSIMDLoadStoreMultipleStructuresPostIndexed: array of TOpcode=(
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100100111110111000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100100000000111000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100100111111010000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100100000001010000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100100111110110000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100100000000110000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100100111110010000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100100000000010000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100100111111000000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100100000001000000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100100111110100000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100100000000100000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111111111111111000000000000; value:%00001100100111110000000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100100000000000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100110111110111000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100110000000111000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100110111111010000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100110000001010000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100110111110110000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100110000000110000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100110111110010000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100110000000010000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100110111111000000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100110000001000000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111100111111111000000000000; value:%00001100110111110100000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100110000000100000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm32or64; offset:30)); mask:%10111111111111111111000000000000; value:%00001100110111110000000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vector; offset:0; maxval: 4; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));      mask:%10111111111000001111000000000000; value:%00001100110000000000000000000000)

  );
  ArmInstructionsAdvSIMDLoadStoreSingleStructure: array of TOpcode=(
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101000000000000000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101000000000100000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101000000001000000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101000000001000010000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101001000000000000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101001000000100000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101001000001000000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101001000001000010000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101000000000010000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101000000000110000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101000000001010000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101000000001010010000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101001000000010000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101001000000110000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101001000001010000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101001000001010010000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101010000000000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101010000000100000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101010000001000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:1; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101010000001000010000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101011000000000000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101011000000100000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101011000001000000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101011000001000010000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101010000000010000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101010000000110000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101010000001010000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101010000001010010000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110000000000000; value:%00001101011000000010000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110010000000000; value:%00001101011000000110000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111110110000000000; value:%00001101011000001010000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset: 5; maxval:3; extra:0; optional: false; defvalue:0; index:ind_single));   mask:%10111111111111111111110000000000; value:%00001101011000001010010000000000),
    (mnemonic:'LD1R'; params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001101010000001100000000000000),
    (mnemonic:'LD2R'; params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001101011000001100000000000000),
    (mnemonic:'LD3R'; params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001101010000001110000000000000),
    (mnemonic:'LD4R'; params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000000110000000000; ),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single)); mask:%10111111111111111111000000000000; value:%00001101011000001110000000000000)
  );
  ArmInstructionsAdvSIMDLoadStoreSingleStructurePostIndexed: array of TOpcode=(
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101100111110000000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101100000000000000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101100111110100000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101100000000100000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101100111111000000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101100000001000000000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101100111111000010000000000),
    (mnemonic:'ST1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101100000001000010000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101101111110000000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101101000000000000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101101111110100000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101101000000100000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101101111111000000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101101000001000000000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101101111111000010000000000),
    (mnemonic:'ST2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101101000001000010000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101100111110010000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101100000000010000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101100111110110000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101100000000110000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101100111111010000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101100000001010000000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101100111111010010000000000),
    (mnemonic:'ST3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101100000001010010000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101101111110010000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101101000000010000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101101111110110000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101101000000110000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101101111111010000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101101000001010000000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101101111111010010000000000),
    (mnemonic:'ST4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101101000001010010000000000),

    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101100111110000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101100000000000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101100111110100000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101100000000100000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101100111111000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101100000001000000000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101100111111000010000000000),
    (mnemonic:'LD1';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 1; extra:%01000000000000000001110000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101100000001000010000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101101111110000000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101101000000000000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101101111110100000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101101000000100000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101101111111000000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101101000001000000000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101101111111000010000000000),
    (mnemonic:'LD2';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 2; extra:%01000000000000000001100000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101101000001000010000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101100111110010000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101100000000010000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101100111110110000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101100000000110000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101100111111010000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101100000001010000000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101100111111010010000000000),
    (mnemonic:'LD3';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 3; extra:%01000000000000000001000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101100000001010010000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val1;));         mask:%10111111111111111110000000000000; value:%00001101101111110010000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('B')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110000000000000; value:%00001101101000000010000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val2;));         mask:%10111111111111111110010000000000; value:%00001101101111110110000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('H')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110010000000000; value:%00001101101000000110000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val4;));         mask:%10111111111111111110110000000000; value:%00001101101111111010000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('S')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001110110000000000; value:%00001101101000001010000000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_val8;));         mask:%10111111111111111111110000000000; value:%00001101101111111010010000000000),
    (mnemonic:'LD4';  params:((ptype:pt_reglist_vectorsingle; offset:0; maxval: 4; extra:%01000000000000000000000000000000 or (qword(ord('D')) shl 32)),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_xreg; offset:16));   mask:%10111111111000001111110000000000; value:%00001101101000001010010000000000),

    (mnemonic:'LD1R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111111111111000000000000; value:%00001101110111111100000000000000),
    (mnemonic:'LD1R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 1; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111000001111000000000000; value:%00001101110000001100000000000000),
    (mnemonic:'LD2R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111111111111000000000000; value:%00001101111111111100000000000000),
    (mnemonic:'LD2R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 2; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111000001111000000000000; value:%00001101111000001110000000000000),
    (mnemonic:'LD3R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111111111111000000000000; value:%00001101110111111110000000000000),
    (mnemonic:'LD3R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111000001111000000000000; value:%00001101110000001110000000000000),
    (mnemonic:'LD4R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111111111111000000000000; value:%00001101111111111110000000000000),
    (mnemonic:'LD4R';  params:((ptype:pt_reglist_vector; offset:0; maxval: 3; extra:%01000000000000000001100000000000),(ptype:pt_xreg; offset:0; maxval:0; extra: 0; optional: false; defvalue:0; index:ind_single),(ptype:pt_imm_1shlval; offset: 10; maxval: 3)); mask:%10111111111000001111000000000000; value:%00001101111000001110000000000000)
  );

  ArmInstructionsPCRelAddressing: array of TOpcode=(
    (mnemonic:'ADR';  params:((ptype:pt_xreg; offset:0),(ptype:pt_addrlabel; offset:5; maxval:0; extra: 0 )); mask:%10011111000000000000000000000000; value:%00010000000000000000000000000000),
    (mnemonic:'ADRP'; params:((ptype:pt_xreg; offset:0),(ptype:pt_addrlabel; offset:5; maxval:0; extra: 1 )); mask:%10011111000000000000000000000000; value:%10010000000000000000000000000000)
  );

  ArmInstructionsAddSubtractImm: array of TOpcode=(
    (mnemonic:'MOV';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5)); mask:%11111111111111111111111111100000; value:%00010001000000000000001111100000),
    (mnemonic:'MOV';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5)); mask:%11111111111111111111111111100000; value:%10010001000000000000001111100000),
    (mnemonic:'MOV';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5)); mask:%11111111111111111111100000111111; value:%00010001000000000000000000011111),
    (mnemonic:'MOV';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5)); mask:%11111111111111111111100000111111; value:%10010001000000000000000000011111),

    (mnemonic:'CMN';  params:((ptype:pt_wreg; offset:0),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000011111; value:%00110001000000000000000000011111),
    (mnemonic:'CMN';  params:((ptype:pt_xreg; offset:0),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000011111; value:%10110001000000000000000000011111),
    (mnemonic:'CMP';  params:((ptype:pt_wreg; offset:0),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000011111; value:%01110001000000000000000000011111),
    (mnemonic:'CMP';  params:((ptype:pt_xreg; offset:0),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000011111; value:%11110001000000000000000000011111),

    (mnemonic:'ADD';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%00010001000000000000000000000000),
    (mnemonic:'ADD';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%10010001000000000000000000000000),
    (mnemonic:'ADDS';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%00110001000000000000000000000000),
    (mnemonic:'ADDS';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%10110001000000000000000000000000),

    (mnemonic:'SUB';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%01010001000000000000000000000000),
    (mnemonic:'SUB';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%11010001000000000000000000000000),
    (mnemonic:'SUBS';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%01110001000000000000000000000000),
    (mnemonic:'SUBS';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm; offset: 10; maxval:$fff), (ptype:pt_lsl0or12; offset:22; maxval:3; extra:0; optional: true; defvalue:0));  mask:%11111111000000000000000000000000; value:%11110001000000000000000000000000)

  );

  ArmInstructionsLogicalImm: array of TOpcode=(
    (mnemonic:'AND';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:32));  mask:%11111111100000000000000000000000; value:%00010010000000000000000000000000),
    (mnemonic:'AND';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:64));  mask:%11111111100000000000000000000000; value:%10010010000000000000000000000000),
    (mnemonic:'ORR';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:32));  mask:%11111111110000000000000000000000; value:%00110010000000000000000000000000),
    (mnemonic:'ORR';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:64));  mask:%11111111100000000000000000000000; value:%10110010000000000000000000000000),
    (mnemonic:'EOR';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:32));  mask:%11111111110000000000000000000000; value:%01010010000000000000000000000000),
    (mnemonic:'EOR';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:64));  mask:%11111111100000000000000000000000; value:%11010010000000000000000000000000),
    (mnemonic:'TST';  params:((ptype:pt_wreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:32));  mask:%11111111110000000000000000011111; value:%01110010000000000000000000011111),
    (mnemonic:'TST';  params:((ptype:pt_xreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:64));  mask:%11111111100000000000000000011111; value:%11110010000000000000000000011111),
    (mnemonic:'ANDS';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:32));  mask:%11111111110000000000000000000000; value:%01110010000000000000000000000000),
    (mnemonic:'ANDS';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm_bitmask; offset: 10; maxval:$1fff; extra:64));  mask:%11111111100000000000000000000000; value:%11110010000000000000000000000000)
  );

  ArmInstructionsMoveWideImm: array of TOpcode=(
    (mnemonic:'MOVN';  params:((ptype:pt_wreg; offset:0),(ptype:pt_imm; offset:5; maxval: $ffff),(ptype:pt_lsldiv16; offset: 21; maxval:3));  mask:%11111111100000000000000000000000; value:%00010010100000000000000000000000),
    (mnemonic:'MOVN';  params:((ptype:pt_xreg; offset:0),(ptype:pt_imm; offset:5; maxval: $ffff),(ptype:pt_lsldiv16; offset: 21; maxval:3));  mask:%11111111100000000000000000000000; value:%10010010100000000000000000000000),
    (mnemonic:'MOVZ';  params:((ptype:pt_wreg; offset:0),(ptype:pt_imm; offset:5; maxval: $ffff),(ptype:pt_lsldiv16; offset: 21; maxval:3));  mask:%11111111100000000000000000000000; value:%01010010100000000000000000000000),
    (mnemonic:'MOVZ';  params:((ptype:pt_xreg; offset:0),(ptype:pt_imm; offset:5; maxval: $ffff),(ptype:pt_lsldiv16; offset: 21; maxval:3));  mask:%11111111100000000000000000000000; value:%11010010100000000000000000000000),
    (mnemonic:'MOVK';  params:((ptype:pt_wreg; offset:0),(ptype:pt_imm; offset:5; maxval: $ffff),(ptype:pt_lsldiv16; offset: 21; maxval:3));  mask:%11111111100000000000000000000000; value:%01110010100000000000000000000000),
    (mnemonic:'MOVK';  params:((ptype:pt_xreg; offset:0),(ptype:pt_imm; offset:5; maxval: $ffff),(ptype:pt_lsldiv16; offset: 21; maxval:3));  mask:%11111111100000000000000000000000; value:%11110010100000000000000000000000)
  );

  ArmInstructionsBitField: array of TOpcode=(
    (mnemonic:'SBFM';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm; offset: 16; maxval:$3f), (ptype:pt_imm; offset: 10; maxval:$3f));  mask:%11111111110000000000000000000000; value:%00010011000000000000000000000000),
    (mnemonic:'SBFM';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm; offset: 16; maxval:$3f), (ptype:pt_imm; offset: 10; maxval:$3f));  mask:%11111111110000000000000000000000; value:%10010011010000000000000000000000),

    (mnemonic:'BFM';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm; offset: 16; maxval:$3f), (ptype:pt_imm; offset: 10; maxval:$3f));   mask:%11111111110000000000000000000000; value:%00110011000000000000000000000000),
    (mnemonic:'BFM';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm; offset: 16; maxval:$3f), (ptype:pt_imm; offset: 10; maxval:$3f));   mask:%11111111110000000000000000000000; value:%00110011010000000000000000000000),

    (mnemonic:'UBFM';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_imm; offset: 16; maxval:$3f), (ptype:pt_imm; offset: 10; maxval:$3f));  mask:%11111111110000000000000000000000; value:%01010011000000000000000000000000),
    (mnemonic:'UBFM';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_imm; offset: 16; maxval:$3f), (ptype:pt_imm; offset: 10; maxval:$3f));  mask:%11111111110000000000000000000000; value:%11010011010000000000000000000000)
  );

  ArmInstructionsExtract: array of TOpcode=(
  //if param1=param2 then ror
    (mnemonic:'ROR';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg2x;  offset:5; maxval: 0; extra:16),(ptype:pt_imm; offset: 10; maxval:$3f));  mask:%01111111111000000000000000000000; value:%00010011100000000000000000000000 ),
    (mnemonic:'ROR';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg2x;  offset:5; maxval: 0; extra:16),(ptype:pt_imm; offset: 10; maxval:$3f));  mask:%01111111111000000000000000000000; value:%00010011100000000000000000000000),
    (mnemonic:'EXTR';  params:((ptype:pt_wreg; offset:0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:5), (ptype:pt_imm; offset: 10; maxval:$3f));  mask:%11111111111000000000000000000000; value:%00010011100000000000000000000000),
    (mnemonic:'EXTR';  params:((ptype:pt_xreg; offset:0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:5), (ptype:pt_imm; offset: 10; maxval:$3f));  mask:%11111111111000000000000000000000; value:%10010011110000000000000000000000)
  );


  ArmInstructionsLogicalShiftedRegister: array of TOpcode=(
    (mnemonic:'AND'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%00001010000000000000000000000000),
    (mnemonic:'AND'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%10001010000000000000000000000000),

    (mnemonic:'BIC'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%00001010001000000000000000000000),
    (mnemonic:'BIC'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%10001010001000000000000000000000),


    (mnemonic:'MOV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:16) );  mask:%11111111111000001111111111100000; value:%00101010000000000000001111100000),
    (mnemonic:'MOV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:16) );  mask:%11111111111000001111111111100000; value:%10101010000000000000001111100000),
    (mnemonic:'ORR'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%00101010000000000000000000000000),
    (mnemonic:'ORR'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%10101010000000000000000000000000),

    (mnemonic:'MVN'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;) );  mask:%11111111001000000000001111100000; value:%00101010001000000000001111100000),
    (mnemonic:'MVN'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;) );  mask:%11111111001000000000001111100000; value:%10101010001000000000001111100000),
    (mnemonic:'ORN'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%00101010001000000000000000000000),
    (mnemonic:'ORN'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%10101010001000000000000000000000),

    (mnemonic:'EOR'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%01001010000000000000000000000000),
    (mnemonic:'EOR'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%11001010000000000000000000000000),

    (mnemonic:'EON'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%01001010001000000000000000000000),
    (mnemonic:'EON'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%11001010001000000000000000000000),


    (mnemonic:'TST'; params:((ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;) );  mask:%11111111001000000000000000011111; value:%01101010000000000000000000011111),
    (mnemonic:'TST'; params:((ptype:pt_wreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;) );  mask:%11111111001000000000000000011111; value:%11101010000000000000000000011111),
    (mnemonic:'ANDS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%01101010000000000000000000000000),
    (mnemonic:'ANDS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%11101010000000000000000000000000),

    (mnemonic:'BICS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%01101010001000000000000000000000),
    (mnemonic:'BICS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%11101010001000000000000000000000)
  );

  ArmInstructionsAddSubtractShiftedRegister: array of TOpcode=(
    (mnemonic:'ADD'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%00001011000000000000000000000000),
    (mnemonic:'ADD'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%10001011000000000000000000000000),

    (mnemonic:'CMN'; params:((ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );                             mask:%11111111001000000000000000011111; value:%00101011000000000000000000011111),
    (mnemonic:'CMN'; params:((ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );                             mask:%11111111001000000000000000011111; value:%10101011000000000000000000011111),

    (mnemonic:'ADDS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  ); mask:%11111111001000000000000000000000; value:%00101011000000000000000000000000),
    (mnemonic:'ADDS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  ); mask:%11111111001000000000000000000000; value:%10101011000000000000000000000000),

    (mnemonic:'NEG'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );                            mask:%11111111001000000000001111100000; value:%01001011000000000000001111100000),
    (mnemonic:'NEG'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );                            mask:%11111111001000000000001111100000; value:%11001011000000000000001111100000),
    (mnemonic:'SUB'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%01001011000000000000000000000000),
    (mnemonic:'SUB'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000000000; value:%11001011000000000000000000000000),


    (mnemonic:'CMP'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000011111; value:%01101011000000000000000000011111),
    (mnemonic:'CMP'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );  mask:%11111111001000000000000000011111; value:%11101011000000000000000000011111),
    (mnemonic:'NEGS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );                           mask:%11111111001000000000001111100000; value:%01101011000000000000001111100000),
    (mnemonic:'NEGS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  );                           mask:%11111111001000000000001111100000; value:%11101011000000000000001111100000),
    (mnemonic:'SUBS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  ); mask:%11111111001000000000000000000000; value:%01101011000000000000000000000000),
    (mnemonic:'SUBS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16),(ptype:pt_shift16; offset:22; maxval: $3f; extra: 10;)  ); mask:%11111111001000000000000000000000; value:%11101011000000000000000000000000)
  );

  ArmInstructionsAddSubtractExtendedRegister: array of TOpcode=(
    (mnemonic:'ADD'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:13),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );                                    mask:%11111111111000000000000000000000; value:%00001011001000000000000000000000),
    (mnemonic:'ADD'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  ); mask:%11111111111000000000000000000000; value:%10001011001000000000000000000000),

    (mnemonic:'CMN'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:13),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );                                   mask:%11111111111000000000000000011111; value:%00101011001000000000000000011111),
    (mnemonic:'CMN'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );mask:%11111111111000000000000000011111; value:%10101011001000000000000000011111),
    (mnemonic:'ADDS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:13),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );                                   mask:%11111111111000000000000000000000; value:%00101011001000000000000000000000),
    (mnemonic:'ADDS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );mask:%11111111111000000000000000000000; value:%10101011001000000000000000000000),

    (mnemonic:'SUB'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:13),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );                                    mask:%11111111111000000000000000000000; value:%01001011001000000000000000000000),
    (mnemonic:'SUB'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  ); mask:%11111111111000000000000000000000; value:%11001011001000000000000000000000),

    (mnemonic:'CMP'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:13),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );                                   mask:%11111111111000000000000000011111; value:%01101011001000000000000000011111),
    (mnemonic:'CMP'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );mask:%11111111111000000000000000011111; value:%11101011001000000000000000011111),

    (mnemonic:'SUBS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:13),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );                                   mask:%11111111111000000000000000000000; value:%01101011001000000000000000000000),
    (mnemonic:'SUBS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_indexwidthspecifier; offset:13; maxval:0; extra:16),(ptype:pt_extend_amount_Extended_Register; offset:13; maxval:0; extra:10)  );mask:%11111111111000000000000000000000; value:%11101011001000000000000000000000)
  );

  ArmInstructionsAddSubtractWithCarry: array of TOpcode=(
    (mnemonic:'ADC'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16)); mask:%11111111111000001111110000000000; value:%00011010000000000000000000000000),
    (mnemonic:'ADC'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16)); mask:%11111111111000001111110000000000; value:%10011010000000000000000000000000),

    (mnemonic:'ADCS';params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16)); mask:%11111111111000001111110000000000; value:%00111010000000000000000000000000),
    (mnemonic:'ADCS';params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16)); mask:%11111111111000001111110000000000; value:%10111010000000000000000000000000),

    (mnemonic:'NGC'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:16));                           mask:%11111111111000001111111111100000; value:%01011010000000000000001111100000),
    (mnemonic:'NGC'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:16));                           mask:%11111111111000001111111111100000; value:%11011010000000000000001111100000),
    (mnemonic:'SBC'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16)); mask:%11111111111000001111110000000000; value:%01011010000000000000000000000000),
    (mnemonic:'SBC'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16)); mask:%11111111111000001111110000000000; value:%11011010000000000000000000000000),


    (mnemonic:'NGCS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16));mask:%11111111111000001111111111100000; value:%01111010000000000000001111100000),
    (mnemonic:'NGCS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16));mask:%11111111111000001111111111100000; value:%11111010000000000000001111100000),
    (mnemonic:'SBCS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset:5),(ptype:pt_wreg; offset:16));mask:%11111111111000001111110000000000; value:%01111010000000000000000000000000),
    (mnemonic:'SBCS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset:5),(ptype:pt_xreg; offset:16));mask:%11111111111000001111110000000000; value:%11111010000000000000000000000000)
  );

  ArmInstructionsConditionalCompareRegister: array of TOpcode=(
    (mnemonic:'CCMN'; params:((ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset:16),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%00111010010000000000000000000000),
    (mnemonic:'CCMN'; params:((ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset:16),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%10111010010000000000000000000000),

    (mnemonic:'CCMP'; params:((ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset:16),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%01111010010000000000000000000000),
    (mnemonic:'CCMP'; params:((ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset:16),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%11111010010000000000000000000000)
  );

  ArmInstructionsConditionalCompareImmediate: array of TOpcode=(
    (mnemonic:'CCMN'; params:((ptype:pt_wreg; offset: 5),(ptype:pt_imm; offset:16; maxval: $1f),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%00111010010000000000100000000000),
    (mnemonic:'CCMN'; params:((ptype:pt_xreg; offset: 5),(ptype:pt_imm; offset:16; maxval: $1f),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%10111010010000000000100000000000),

    (mnemonic:'CCMP'; params:((ptype:pt_wreg; offset: 5),(ptype:pt_imm; offset:16; maxval: $1f),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%01111010010000000000100000000000),
    (mnemonic:'CCMP'; params:((ptype:pt_xreg; offset: 5),(ptype:pt_imm; offset:16; maxval: $1f),(ptype:pt_imm; offset:0; maxval:$f), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000010000; value:%11111010010000000000100000000000)
  );

  ArmInstructionsCondionalSelect: array of TOpcode=(
    (mnemonic:'CSEL'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000;  value:%00011010100000000000000000000000),
    (mnemonic:'CSEL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000;  value:%10011010100000000000000000000000),

    (mnemonic:'CSINC'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000; value:%00011010100000000000010000000000),
    (mnemonic:'CSINC'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000; value:%10011010100000000000010000000000),

    (mnemonic:'CSINV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000; value:%01011010100000000000000000000000),
    (mnemonic:'CSINV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000; value:%11011010100000000000010000000000),

    (mnemonic:'CSNEG'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000; value:%01011010100000000000010000000000),
    (mnemonic:'CSNEG'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16), (ptype:pt_cond; offset:12) ); mask:%11111111111000000000110000000000; value:%11011010100000000000010000000000)

  );


  ArmInstructionsDataProcessing3Source: array of TOpcode=(
    (mnemonic:'MUL'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16)  ); mask:%11111111111000001111110000000000;  value:%00011011000000000111110000000000),
    (mnemonic:'MUL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16)  ); mask:%11111111111000001111110000000000;  value:%10011011000000000111110000000000),

    (mnemonic:'MADD'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16),(ptype:pt_wreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011011000000000000000000000000),
    (mnemonic:'MADD'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16),(ptype:pt_xreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%10011011000000000000000000000000),

    (mnemonic:'MNEG'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16)  ); mask:%11111111111000001111110000000000;  value:%00011011000000001111110000000000),
    (mnemonic:'MNEG'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16)  ); mask:%11111111111000001111110000000000;  value:%10011011000000001111110000000000),

    (mnemonic:'MSUB'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16),(ptype:pt_wreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011011000000001000000000000000),
    (mnemonic:'MSUB'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16),(ptype:pt_xreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%10011011000000001000000000000000),

    (mnemonic:'SMULL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011011001000000111110000000000),
    (mnemonic:'SMADDL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16),(ptype:pt_xreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%10011011001000000000000000000000),

    (mnemonic:'SMNEGL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16)   ); mask:%11111111111000001111110000000000;  value:%10011011001000001111110000000000),
    (mnemonic:'SMSUBL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16),(ptype:pt_xreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%10011011001000001000000000000000),

    (mnemonic:'SMULH'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16)  ); mask:%11111111111000001111110000000000;  value:%10011011010000001111100000000000),


    (mnemonic:'UMULL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011011101000000111110000000000),
    (mnemonic:'UMADDL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16),(ptype:pt_xreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%10011011101000000000000000000000),


    (mnemonic:'UMNEGL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16)  ); mask:%11111111111000001111110000000000;  value:%10011011101000001111110000000000),
    (mnemonic:'UMSUBL'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16),(ptype:pt_xreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%10011011101000001000000000000000),

    (mnemonic:'UMULLH'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_xreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011011110000000111110000000000)


  );

  ArmInstructionsDataProcessing2Source: array of TOpcode=(
    (mnemonic:'UDIV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011010110000000000100000000000),
    (mnemonic:'UDIV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011010110000000000100000000000),

    (mnemonic:'SDIV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011010110000000000110000000000),
    (mnemonic:'SDIV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011010110000000000110000000000),

    (mnemonic:'LSLV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011010110000000010000000000000),
    (mnemonic:'LSLV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011010110000000010000000000000),

    (mnemonic:'LSRV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011010110000000010010000000000),
    (mnemonic:'LSRV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011010110000000010010000000000),

    (mnemonic:'ASRV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011010110000000010100000000000),
    (mnemonic:'ASRV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011010110000000010100000000000),

    (mnemonic:'RORV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011010110000000010110000000000),
    (mnemonic:'RORV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%10011010110000000010110000000000),

    (mnemonic:'CRC32B'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%00011010110000000100000000000000),
    (mnemonic:'CRC32H'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%00011010110000000100010000000000),
    (mnemonic:'CRC32W'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%00011010110000000100100000000000),
    (mnemonic:'CRC32X'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_xreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%10011010110000000100110000000000),

    (mnemonic:'CRC32CB'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%00011010110000000101000000000000),
    (mnemonic:'CRC32CH'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%00011010110000000101010000000000),
    (mnemonic:'CRC32CW'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_wreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%00011010110000000101100000000000),
    (mnemonic:'CRC32CX'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5),(ptype:pt_xreg; offset: 16) ); mask:%11111111111000001111110000000000;value:%10011010110000000101110000000000)


  );

  ArmInstructionsDataProcessing1Source: array of TOpcode=(
    (mnemonic:'RBIT'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%01011010110000000000000000000000),
    (mnemonic:'RBIT'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%11011010110000000000000000000000),

    (mnemonic:'REV16'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%01011010110000000000010000000000),
    (mnemonic:'REV16'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%11011010110000000000010000000000),

    (mnemonic:'REV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%01011010110000000000100000000000),
    (mnemonic:'REV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%11011010110000000000110000000000),

    (mnemonic:'CLZ'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%01011010110000000001000000000000),
    (mnemonic:'CLZ'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%11011010110000000001000000000000),

    (mnemonic:'CLS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_wreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%01011010110000000001010000000000),
    (mnemonic:'CLS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%11011010110000000001010000000000),

    (mnemonic:'REV32'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_xreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%11011010110000000000100000000000)
  );


  ArmInstructionsFloatingPoint_FixedPointConversions: array of TOpcode=(
    (mnemonic:'SCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110000000100000000000000000),
    (mnemonic:'SCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110010000100000000000000000),
    (mnemonic:'SCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110000000100000000000000000),
    (mnemonic:'SCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110010000100000000000000000),

    (mnemonic:'UCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110000000110000000000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110010000110000000000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110000000110000000000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110010000110000000000000000),

    (mnemonic:'FCVTZS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110000110000000000000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110010110000000000000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110000110000000000000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110010110000000000000000000),

    (mnemonic:'FCVTZU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110000110010000000000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_wreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%00011110010110010000000000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110000110010000000000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_xreg; offset: 5), (ptype:pt_scale; offset: 10), (ptype:pt_cond; offset: 12; MaxVal: $3f)); mask:%11111111111111110000000000000000;  value:%10011110010110010000000000000000)
  );

  ArmInstructionsFloatingPointConditionalCompare: array of TOpcode=(
    (mnemonic:'FCCMP'; params:((ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16), (ptype:pt_imm; offset: 16; MaxVal: $f), (ptype:pt_cond; offset: 12; MaxVal: $f)  ); mask:%11111111111000001111110000011111;  value:%00011110001000000010000000000000),
    (mnemonic:'FCCMP'; params:((ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16), (ptype:pt_imm; offset: 16; MaxVal: $f), (ptype:pt_cond; offset: 12; MaxVal: $f)  ); mask:%11111111111000001111110000011111;  value:%00011110011000000010000000000000),

    (mnemonic:'FCCMPE'; params:((ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16), (ptype:pt_imm; offset: 16; MaxVal: $f), (ptype:pt_cond; offset: 12; MaxVal: $f)  ); mask:%11111111111000001111110000011111;  value:%00011110001000000010000000010000),
    (mnemonic:'FCCMPE'; params:((ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16), (ptype:pt_imm; offset: 16; MaxVal: $f), (ptype:pt_cond; offset: 12; MaxVal: $f)  ); mask:%11111111111000001111110000011111;  value:%00011110011000000010000000010000)

  );


  ArmInstructionsFloatingPointDataProcessing2Source: array of TOpcode=(
    (mnemonic:'FMUL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000000100000000000),
    (mnemonic:'FMUL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000000100000000000),

    (mnemonic:'FDIV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000001100000000000),
    (mnemonic:'FDIV'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000001100000000000),

    (mnemonic:'FADD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000010100000000000),
    (mnemonic:'FADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000010100000000000),

    (mnemonic:'FSUB'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000011100000000000),
    (mnemonic:'FSUB'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000011100000000000),

    (mnemonic:'FMAX'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000100100000000000),
    (mnemonic:'FMAX'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000100100000000000),

    (mnemonic:'FMIN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000101100000000000),
    (mnemonic:'FMIN'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000101100000000000),

    (mnemonic:'FMAXNM'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000110100000000000),
    (mnemonic:'FMAXNM'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000110100000000000),

    (mnemonic:'FMINNM'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000000111100000000000),
    (mnemonic:'FMINNM'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000000111100000000000),

    (mnemonic:'FNMUL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110001000001000100000000000),
    (mnemonic:'FNMUL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000000000;  value:%00011110011000001000100000000000)

  );


  ArmInstructionsFloatingPointConditionalSelect: array of TOpcode=(
    (mnemonic:'FCSEL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5), (ptype:pt_sreg; offset: 16), (ptype:pt_cond; offset: 12; MaxVal: $f)  ); mask:%11111111111000000000110000000000;  value:%00011110001000000000110000000000),
    (mnemonic:'FCSEL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5), (ptype:pt_dreg; offset: 16), (ptype:pt_cond; offset: 12; MaxVal: $f)  ); mask:%11111111111000000000110000000000;  value:%00011110011000000000110000000000)
  );

  ArmInstructionsFloatingPointImmediate: array of TOpcode=(
    (mnemonic:'FMOV'; params:((ptype:pt_sreg; offset: 5),(ptype:pt_fpimm8; offset: 14;) ); mask:%11111111111000000001111111100000;  value:%00011110001000000001000000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_dreg; offset: 5),(ptype:pt_fpimm8; offset: 14;) ); mask:%11111111111000000001111111100000;  value:%00011110011000000001000000000000)
  );

  ArmInstructionsFloatingPointCompare: array of TOpcode=(
    (mnemonic:'FCMP'; params:((ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000011111;  value:%00011110001000000010000000000000),
    (mnemonic:'FCMP'; params:((ptype:pt_sreg; offset: 5),(ptype:pt_imm_val0_0) );       mask:%11111111111111111111110000011111;  value:%00011110001000000010000000001000),
    (mnemonic:'FCMP'; params:((ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000011111;  value:%00011110011000000010000000000000),
    (mnemonic:'FCMP'; params:((ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0_0) );       mask:%11111111111111111111110000011111;  value:%00011110011000000010000000001000),

    (mnemonic:'FCMPE'; params:((ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16) ); mask:%11111111111000001111110000011111; value:%00011110001000000010000000010000),
    (mnemonic:'FCMPE'; params:((ptype:pt_sreg; offset: 5),(ptype:pt_imm_val0_0) );       mask:%11111111111111111111110000011111; value:%00011110001000000010000000011000),
    (mnemonic:'FCMPE'; params:((ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16) ); mask:%11111111111000001111110000011111; value:%00011110011000000010000000010000),
    (mnemonic:'FCMPE'; params:((ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0_0) );       mask:%11111111111111111111110000011111; value:%00011110011000000010000000011000)

  );

  ArmInstructionsFloatingPointDataProcessing1Source: array of TOpcode=(
    (mnemonic:'FMOV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110001000000100000000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110011000000100000000000000),

    (mnemonic:'FABS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110001000001100000000000000),
    (mnemonic:'FABS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110011000001100000000000000),

    (mnemonic:'FNEG'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110001000010100000000000000),
    (mnemonic:'FNEG'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110011000010100000000000000),

    (mnemonic:'FSQRT'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5) ); mask:%11111111111111111111110000000000; value:%00011110001000011100000000000000),
    (mnemonic:'FSQRT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5) ); mask:%11111111111111111111110000000000; value:%00011110011000011100000000000000),

    (mnemonic:'FCVT'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_hreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110111000100100000000000000),
    (mnemonic:'FCVT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_hreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110111000101100000000000000),
    (mnemonic:'FCVT'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110001000111100000000000000),
    (mnemonic:'FCVT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_sreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110001000101100000000000000),
    (mnemonic:'FCVT'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_dreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110011000111100000000000000),
    (mnemonic:'FCVT'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5) ); mask:%11111111111111111111110000000000;  value:%00011110011000100100000000000000),

    (mnemonic:'FRINTN'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110001001000100000000000000),
    (mnemonic:'FRINTN'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110011001000100000000000000),

    (mnemonic:'FRINTP'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110001001001100000000000000),
    (mnemonic:'FRINTP'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110011001001100000000000000),

    (mnemonic:'FRINTM'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110001001010100000000000000),
    (mnemonic:'FRINTM'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110011001010100000000000000),

    (mnemonic:'FRINTZ'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110001001011100000000000000),
    (mnemonic:'FRINTZ'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110011001011100000000000000),

    (mnemonic:'FRINTA'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110001001100100000000000000),
    (mnemonic:'FRINTA'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110011001100100000000000000),

    (mnemonic:'FRINTX'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110001001110100000000000000),
    (mnemonic:'FRINTX'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110011001110100000000000000),

    (mnemonic:'FRINTI'; params:((ptype:pt_sreg; offset:0),(ptype:pt_sreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110001001111100000000000000),
    (mnemonic:'FRINTI'; params:((ptype:pt_dreg; offset:0),(ptype:pt_dreg;offset: 5));  mask:%11111111111111111111110000000000;  value:%00011110011001111100000000000000)
  );

  ArmInstructionsFloatingPoint_IntegerConversions: array of TOpcode=(
    (mnemonic:'FCVTNS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001000000000000000000000),
    (mnemonic:'FCVTNS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001000000000000000000000),
    (mnemonic:'FCVTNS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011000000000000000000000),
    (mnemonic:'FCVTNS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011000000000000000000000),

    (mnemonic:'FCVTNU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001000010000000000000000),
    (mnemonic:'FCVTNU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001000010000000000000000),
    (mnemonic:'FCVTNU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011000010000000000000000),
    (mnemonic:'FCVTNU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011000010000000000000000),

    (mnemonic:'SCVTF';  params:((ptype:pt_sreg; offset: 0),(ptype:pt_wreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001000100000000000000000),
    (mnemonic:'SCVTF';  params:((ptype:pt_dreg; offset: 0),(ptype:pt_wreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001000100000000000000000),
    (mnemonic:'SCVTF';  params:((ptype:pt_sreg; offset: 0),(ptype:pt_xreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011000100000000000000000),
    (mnemonic:'SCVTF';  params:((ptype:pt_dreg; offset: 0),(ptype:pt_xreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011000100000000000000000),

    (mnemonic:'UCVTF';  params:((ptype:pt_sreg; offset: 0),(ptype:pt_wreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001000110000000000000000),
    (mnemonic:'UCVTF';  params:((ptype:pt_dreg; offset: 0),(ptype:pt_wreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001000110000000000000000),
    (mnemonic:'UCVTF';  params:((ptype:pt_sreg; offset: 0),(ptype:pt_xreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011000110000000000000000),
    (mnemonic:'UCVTF';  params:((ptype:pt_dreg; offset: 0),(ptype:pt_xreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011000110000000000000000),

    (mnemonic:'FCVTAS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001001000000000000000000),
    (mnemonic:'FCVTAS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001001000000000000000000),
    (mnemonic:'FCVTAS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011001000000000000000000),
    (mnemonic:'FCVTAS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011001000000000000000000),

    (mnemonic:'FCVTAU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001001010000000000000000),
    (mnemonic:'FCVTAU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001001010000000000000000),
    (mnemonic:'FCVTAU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011001010000000000000000),
    (mnemonic:'FCVTAU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011001010000000000000000),

    (mnemonic:'FMOV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_wreg; offset: 5) );    mask:%11111111111111111111110000000000;  value:%00011110001001110000000000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );    mask:%11111111111111111111110000000000;  value:%00011110001001100000000000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_xreg; offset: 5) );    mask:%11111111111111111111110000000000;  value:%10011110011001110000000000000000),
    (mnemonic:'FMOV';params:((ptype:pt_vreg_D_Index1;offset:0),(ptype:pt_xreg;offset:5)); mask:%11111111111111111111110000000000;  value:%10011110101011110000000000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );    mask:%11111111111111111111110000000000;  value:%10011110011001100000000000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_vreg_D_Index1; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110101011100000000000000000),

    (mnemonic:'FCVTPS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001010000000000000000000),
    (mnemonic:'FCVTPS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001010000000000000000000),
    (mnemonic:'FCVTPS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011010000000000000000000),
    (mnemonic:'FCVTPS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011010000000000000000000),

    (mnemonic:'FCVTPU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001010010000000000000000),
    (mnemonic:'FCVTPU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001010010000000000000000),
    (mnemonic:'FCVTPU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011010010000000000000000),
    (mnemonic:'FCVTPU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011010010000000000000000),

    (mnemonic:'FCVTMS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001100000000000000000000),
    (mnemonic:'FCVTMS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001100000000000000000000),
    (mnemonic:'FCVTMS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011100000000000000000000),
    (mnemonic:'FCVTMS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011100000000000000000000),

    (mnemonic:'FCVTMU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001100010000000000000000),
    (mnemonic:'FCVTMU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001100010000000000000000),
    (mnemonic:'FCVTMU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011100010000000000000000),
    (mnemonic:'FCVTMU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011100010000000000000000),

    (mnemonic:'FCVTZS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001110000000000000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001110000000000000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011110000000000000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011110000000000000000000),

    (mnemonic:'FCVTZU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110001110010000000000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_sreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110001110010000000000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%00011110011110010000000000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_dreg; offset: 5) );  mask:%11111111111111111111110000000000;  value:%10011110011110010000000000000000)
  );

  ArmInstructionsFloatingPointDataProcessing3Source: array of TOpcode=(
    (mnemonic:'FMADD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16),(ptype:pt_sreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111000000000000000000000000),
    (mnemonic:'FMADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16),(ptype:pt_dreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111010000000000000000000000),

    (mnemonic:'FMSUB'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16),(ptype:pt_sreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111000000001000000000000000),
    (mnemonic:'FMSUB'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16),(ptype:pt_dreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111010000001000000000000000),

    (mnemonic:'FNMADD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16),(ptype:pt_sreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111001000000000000000000000),
    (mnemonic:'FNMADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16),(ptype:pt_dreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111011000000000000000000000),

    (mnemonic:'FNMSUB'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16),(ptype:pt_sreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111001000001000000000000000),
    (mnemonic:'FNMSUB'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16),(ptype:pt_dreg; offset: 10)  ); mask:%11111111111000001000000000000000;  value:%00011111011000001000000000000000)
  );

  ArmInstructionsAdvSIMDThreeSame: array of TOpcode=(
    (mnemonic:'SHADD'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16));  mask:%10111111001000001111110000000000; value:%00001110001000000000010000000000),
    (mnemonic:'SQADD'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16));                             mask:%10111111001000001111110000000000; value:%00001110001000000000110000000000),
    (mnemonic:'SRHADD'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000; value:%00001110001000000001010000000000),
    (mnemonic:'SHSUB'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000010010000000000),
    (mnemonic:'SQSUB'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000010110000000000),
    (mnemonic:'CMGT'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),   (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000011010000000000),
    (mnemonic:'CMGE'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),   (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000011110000000000),
    (mnemonic:'SSHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),   (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000100010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000100110000000000),
    (mnemonic:'SRSHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000101010000000000),
    (mnemonic:'SQRSHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000; value:%00001110001000000101110000000000),
    (mnemonic:'SMAX'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000110010000000000),
    (mnemonic:'SMIN'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000110110000000000),
    (mnemonic:'SABD'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000111010000000000),
    (mnemonic:'SABA'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000000111110000000000),
    (mnemonic:'ADD';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16));                            mask:%10111111001000001111110000000000;  value:%00001110001000001000010000000000),
    (mnemonic:'CMTST';params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16));                            mask:%10111111001000001111110000000000;  value:%00001110001000001000110000000000),
    (mnemonic:'MLA';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000001001010000000000),
    (mnemonic:'MUL';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000001001110000000000),
    (mnemonic:'SMAXP'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5), (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000001010010000000000),
    (mnemonic:'SMINP'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5), (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000001010110000000000),
    (mnemonic:'SQDMULH';params:((ptype:pt_vreg_T_sizenot3; offset:0),(ptype:pt_vreg_T_sizenot3; offset:5), (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00001110001000001011010000000000),
    (mnemonic:'ADDP';params:((ptype:pt_vreg_T; offset:0),(ptype:pt_vreg_T; offset:5), (ptype:pt_vreg_T; offset:16));                               mask:%10111111001000001111110000000000;  value:%00001110001000001011110000000000),

    (mnemonic:'FMAXNM';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));           mask:%10111111101000001111110000000000;  value:%00001110001000001100010000000000),
    (mnemonic:'FMLA'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));           mask:%10111111101000001111110000000000;  value:%00001110001000001100110000000000),
    (mnemonic:'FADD'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));           mask:%10111111101000001111110000000000;  value:%00001110001000001101010000000000),
    (mnemonic:'FMULX'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));          mask:%10111111101000001111110000000000;  value:%00001110001000001101110000000000),
    (mnemonic:'FCMEQ'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));          mask:%10111111101000001111110000000000;  value:%00001110001000001110010000000000),
    (mnemonic:'FMAX'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));           mask:%10111111101000001111110000000000;  value:%00001110001000001111010000000000),
    (mnemonic:'FRECPS'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));         mask:%10111111101000001111110000000000;  value:%00001110001000001111110000000000),


    (mnemonic:'ADD';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00001110001000000001110000000000),
    (mnemonic:'ADD';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01001110001000000001110000000000),
    (mnemonic:'BIC';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00001110011000000001110000000000),
    (mnemonic:'BIC';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01001110011000000001110000000000),

    (mnemonic:'FMINNM';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));           mask:%10111111101000001111110000000000;  value:%00001110101000001100010000000000),
    (mnemonic:'FMLS';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));             mask:%10111111101000001111110000000000;  value:%00001110101000001100110000000000),
    (mnemonic:'FSUB';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));             mask:%10111111101000001111110000000000;  value:%00001110101000001101010000000000),
    (mnemonic:'FMIN';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));             mask:%10111111101000001111110000000000;  value:%00001110101000001111010000000000),
    (mnemonic:'FRSQRTS';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));          mask:%10111111101000001111110000000000;  value:%00001110101000001111110000000000),

    (mnemonic:'ORR';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00001110101000000001110000000000),
    (mnemonic:'ORR';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01001110101000000001110000000000),
    (mnemonic:'ORN';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00001110111000000001110000000000),
    (mnemonic:'ORN';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01001110111000000001110000000000),


    (mnemonic:'UHADD'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16));  mask:%10111111001000001111110000000000; value:%00101110001000000000010000000000),
    (mnemonic:'UQADD'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16));                             mask:%10111111001000001111110000000000; value:%00101110001000000000110000000000),
    (mnemonic:'URHADD'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000; value:%00101110001000000001010000000000),
    (mnemonic:'UHSUB'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16));  mask:%10111111001000001111110000000000; value:%00101110001000000010010000000000),
    (mnemonic:'UQSUB'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16));                             mask:%10111111001000001111110000000000; value:%00101110001000000010110000000000),

    (mnemonic:'CMHI'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),   (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000011010000000000),
    (mnemonic:'CMHS'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),   (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000011110000000000),
    (mnemonic:'USHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),   (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000100010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000100110000000000),
    (mnemonic:'URSHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000101010000000000),
    (mnemonic:'UQRSHL'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16)); mask:%10111111001000001111110000000000; value:%00101110001000000101110000000000),
    (mnemonic:'UMAX'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000110010000000000),
    (mnemonic:'UMIN'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000110110000000000),
    (mnemonic:'UABD'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000111010000000000),
    (mnemonic:'UABA'; params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000000111110000000000),

    (mnemonic:'SUB';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16));                            mask:%10111111001000001111110000000000;  value:%00101110001000001000010000000000),
    (mnemonic:'CMEQ';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),  (ptype:pt_vreg_T; offset:16));                           mask:%10111111001000001111110000000000;  value:%00101110001000001000110000000000),
    (mnemonic:'MLS';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000001001010000000000),

    (mnemonic:'PMUL'; params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5), (ptype:pt_vreg_8B; offset:16));           mask:%11111111111000001111110000000000;  value:%00101110001000001001110000000000),
    (mnemonic:'PMUL'; params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5), (ptype:pt_vreg_16B; offset:16));        mask:%11111111111000001111110000000000;  value:%01101110001000001001110000000000),
    (mnemonic:'UMAXP';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000001010010000000000),
    (mnemonic:'UMINP';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16));     mask:%10111111001000001111110000000000;  value:%00101110001000001010110000000000),
    (mnemonic:'SQRDMULH';  params:((ptype:pt_vreg_T_sizenot3or0; offset:0), (ptype:pt_vreg_T_sizenot3or0; offset:5),  (ptype:pt_vreg_T_sizenot3or0; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000001011010000000000),

    (mnemonic:'FMAXNMP';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));           mask:%10111111101000001111110000000000;  value:%00101110001000001100010000000000),
    (mnemonic:'FADDP';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));             mask:%10111111101000001111110000000000;  value:%00101110001000001101010000000000),
    (mnemonic:'FMUL'; params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));             mask:%10111111101000001111110000000000;  value:%00101110001000001101110000000000),
    (mnemonic:'FCMGE'; params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));            mask:%10111111101000001111110000000000;  value:%00101110001000001110010000000000),
    (mnemonic:'FACGE'; params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));            mask:%10111111101000001111110000000000;  value:%00101110001000001110110000000000),
    (mnemonic:'FMAXP'; params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));            mask:%10111111101000001111110000000000;  value:%00101110001000001111010000000000),
    (mnemonic:'FDIV'; params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));             mask:%10111111101000001111110000000000;  value:%00101110001000001111110000000000),

    (mnemonic:'EOR';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00101110001000000001110000000000),
    (mnemonic:'EOR';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01101110001000000001110000000000),
    (mnemonic:'BSL';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00101110011000000001110000000000),
    (mnemonic:'BSL';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01101110011000000001110000000000),

    (mnemonic:'FMINNMP';params:((ptype:pt_vreg_SD_2bit; offset:0),(ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));          mask:%10111111101000001111110000000000;  value:%00101110101000001100010000000000),
    (mnemonic:'FABD'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));           mask:%10111111101000001111110000000000;  value:%00101110101000001101010000000000),
    (mnemonic:'FCMGT'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));          mask:%10111111101000001111110000000000;  value:%00101110101000001110010000000000),
    (mnemonic:'FACGT'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));          mask:%10111111101000001111110000000000;  value:%00101110101000001110110000000000),
    (mnemonic:'FMINP'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5), (ptype:pt_vreg_SD_2bit; offset:16));          mask:%10111111101000001111110000000000;  value:%00101110101000001111010000000000),

    (mnemonic:'BIT';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00101110101000000001110000000000),
    (mnemonic:'BIT';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01101110101000000001110000000000),
    (mnemonic:'BIF';  params:((ptype:pt_vreg_8B; offset:0), (ptype:pt_vreg_8B; offset:5),  (ptype:pt_vreg_8B; offset:16));                         mask:%11111111111000001111110000000000;  value:%00101110111000000001110000000000),
    (mnemonic:'BIF';  params:((ptype:pt_vreg_16B; offset:0), (ptype:pt_vreg_16B; offset:5),  (ptype:pt_vreg_16B; offset:16));                      mask:%11111111111000001111110000000000;  value:%01101110111000000001110000000000)
  );

  ArmInstructionsAdvSIMDThreeDifferent: array of TOpcode=(
    (mnemonic:'SADDL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000000000000000000),
    (mnemonic:'SADDL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5), (ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;value:%01001110001000000000000000000000),
    (mnemonic:'SADDL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000000000000000000),
    (mnemonic:'SADDL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5),  (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;value:%01001110011000000000000000000000),
    (mnemonic:'SADDL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000000000000000000),
    (mnemonic:'SADDL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5),  (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;value:%01001110101000000000000000000000),

    (mnemonic:'SADDW'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000001000000000000),
    (mnemonic:'SADDW2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000000001000000000000),
    (mnemonic:'SADDW'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000001000000000000),
    (mnemonic:'SADDW2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000000001000000000000),
    (mnemonic:'SADDW'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000001000000000000),
    (mnemonic:'SADDW2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000000001000000000000),

    (mnemonic:'SSUBL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000010000000000000),
    (mnemonic:'SSUBL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000000010000000000000),
    (mnemonic:'SSUBL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000010000000000000),
    (mnemonic:'SSUBL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000000010000000000000),
    (mnemonic:'SSUBL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000010000000000000),
    (mnemonic:'SSUBL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000000010000000000000),

    (mnemonic:'SSUBW'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000011000000000000),
    (mnemonic:'SSUBW2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000000011000000000000),
    (mnemonic:'SSUBW'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000011000000000000),
    (mnemonic:'SSUBW2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000000011000000000000),
    (mnemonic:'SSUBW'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000011000000000000),
    (mnemonic:'SSUBW2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000000011000000000000),

    (mnemonic:'ADDHN'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000100000000000000),
    (mnemonic:'ADDHN2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000000100000000000000),
    (mnemonic:'ADDHN'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000100000000000000),
    (mnemonic:'ADDHN2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000000100000000000000),
    (mnemonic:'ADDHN'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000100000000000000),
    (mnemonic:'ADDHN2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000000100000000000000),

    (mnemonic:'SABAL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000101000000000000),
    (mnemonic:'SABAL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000000101000000000000),
    (mnemonic:'SABAL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000101000000000000),
    (mnemonic:'SABAL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000000101000000000000),
    (mnemonic:'SABAL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000101000000000000),
    (mnemonic:'SABAL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000000101000000000000),

    (mnemonic:'SUBHN'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000110000000000000),
    (mnemonic:'SUBHN2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000000110000000000000),
    (mnemonic:'SUBHN'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000110000000000000),
    (mnemonic:'SUBHN2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000000110000000000000),
    (mnemonic:'SUBHN'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000110000000000000),
    (mnemonic:'SUBHN2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000000110000000000000),

    (mnemonic:'SABDL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000000111000000000000),
    (mnemonic:'SABDL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000000111000000000000),
    (mnemonic:'SABDL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000000111000000000000),
    (mnemonic:'SABDL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000000111000000000000),
    (mnemonic:'SABDL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000000111000000000000),
    (mnemonic:'SABDL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000000111000000000000),

    (mnemonic:'SMLAL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000001000000000000000),
    (mnemonic:'SMLAL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000001000000000000000),
    (mnemonic:'SMLAL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000001000000000000000),
    (mnemonic:'SMLAL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000001000000000000000),
    (mnemonic:'SMLAL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000001000000000000000),
    (mnemonic:'SMLAL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000001000000000000000),

    (mnemonic:'SQDMLAL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000001001000000000000),
    (mnemonic:'SQDMLAL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000001001000000000000),
    (mnemonic:'SQDMLAL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000001001000000000000),
    (mnemonic:'SQDMLAL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000001001000000000000),
    (mnemonic:'SQDMLAL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000001001000000000000),
    (mnemonic:'SQDMLAL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000001001000000000000),

    (mnemonic:'SMLSL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110001000001010000000000000),
    (mnemonic:'SMLSL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;   value:%01001110001000001010000000000000),
    (mnemonic:'SMLSL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110011000001010000000000000),
    (mnemonic:'SMLSL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;   value:%01001110011000001010000000000000),
    (mnemonic:'SMLSL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110101000001010000000000000),
    (mnemonic:'SMLSL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;   value:%01001110101000001010000000000000),

    (mnemonic:'SQDMLSL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000001011000000000000),
    (mnemonic:'SQDMLSL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000001011000000000000),
    (mnemonic:'SQDMLSL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000001011000000000000),
    (mnemonic:'SQDMLSL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000001011000000000000),
    (mnemonic:'SQDMLSL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000001011000000000000),
    (mnemonic:'SQDMLSL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000001011000000000000),

    (mnemonic:'SMULL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110001000001100000000000000),
    (mnemonic:'SMULL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;   value:%01001110001000001100000000000000),
    (mnemonic:'SMULL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110011000001100000000000000),
    (mnemonic:'SMULL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;   value:%01001110011000001100000000000000),
    (mnemonic:'SMULL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110101000001100000000000000),
    (mnemonic:'SMULL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;   value:%01001110101000001100000000000000),

    (mnemonic:'SQDMULL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110001000001101000000000000),
    (mnemonic:'SQDMULL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01001110001000001101000000000000),
    (mnemonic:'SQDMULL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110011000001101000000000000),
    (mnemonic:'SQDMULL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110011000001101000000000000),
    (mnemonic:'SQDMULL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00001110101000001101000000000000),
    (mnemonic:'SQDMULL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01001110101000001101000000000000),

    (mnemonic:'PMULL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110001000001110000000000000),
    (mnemonic:'PMULL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;   value:%01001110001000001110000000000000),
    (mnemonic:'PMULL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110011000001110000000000000),
    (mnemonic:'PMULL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;   value:%01001110011000001110000000000000),
    (mnemonic:'PMULL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000;   value:%00001110101000001110000000000000),
    (mnemonic:'PMULL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;   value:%01001110101000001110000000000000),

    (mnemonic:'UADDL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000000000000000000000),
    (mnemonic:'UADDL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5), (ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;value:%01101110001000000000000000000000),
    (mnemonic:'UADDL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000000000000000000000),
    (mnemonic:'UADDL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5),  (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;value:%01101110011000000000000000000000),
    (mnemonic:'UADDL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000000000000000000000),
    (mnemonic:'UADDL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5),  (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;value:%01101110101000000000000000000000),


    (mnemonic:'UADDW'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000000001000000000000),
    (mnemonic:'UADDW2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01101110001000000001000000000000),
    (mnemonic:'UADDW'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000000001000000000000),
    (mnemonic:'UADDW2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110011000000001000000000000),
    (mnemonic:'UADDW'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000000001000000000000),
    (mnemonic:'UADDW2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110101000000001000000000000),

    (mnemonic:'USUBL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000000010000000000000),
    (mnemonic:'USUBL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01101110001000000010000000000000),
    (mnemonic:'USUBL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000000010000000000000),
    (mnemonic:'USUBL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110011000000010000000000000),
    (mnemonic:'USUBL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000000010000000000000),
    (mnemonic:'USUBL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110101000000010000000000000),

    (mnemonic:'USUBW'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000000011000000000000),
    (mnemonic:'USUBW2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01101110001000000011000000000000),
    (mnemonic:'USUBW'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000000011000000000000),
    (mnemonic:'USUBW2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110011000000011000000000000),
    (mnemonic:'USUBW'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000000011000000000000),
    (mnemonic:'USUBW2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110101000000011000000000000),


    (mnemonic:'RADDHN'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000;value:%00101110001000000100000000000000),
    (mnemonic:'RADDHN2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;value:%01101110001000000100000000000000),
    (mnemonic:'RADDHN'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000;value:%00101110011000000100000000000000),
    (mnemonic:'RADDHN2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;value:%01101110011000000100000000000000),
    (mnemonic:'RADDHN'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000;value:%00101110101000000100000000000000),
    (mnemonic:'RADDHN2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;value:%01101110101000000100000000000000),

    (mnemonic:'UABAL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000000101000000000000),
    (mnemonic:'UABAL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01101110001000000101000000000000),
    (mnemonic:'UABAL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000000101000000000000),
    (mnemonic:'UABAL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110011000000101000000000000),
    (mnemonic:'UABAL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000000101000000000000),
    (mnemonic:'UABAL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110101000000101000000000000),

    (mnemonic:'RSUBHN'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000000110000000000000),
    (mnemonic:'RSUBHN2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01101110001000000110000000000000),
    (mnemonic:'RSUBHN'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000000110000000000000),
    (mnemonic:'RSUBHN2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110011000000110000000000000),
    (mnemonic:'RSUBHN'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000000110000000000000),
    (mnemonic:'RSUBHN2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110101000000110000000000000),

    (mnemonic:'UABDL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000000111000000000000),
    (mnemonic:'UABDL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01101110001000000111000000000000),
    (mnemonic:'UABDL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000000111000000000000),
    (mnemonic:'UABDL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110011000000111000000000000),
    (mnemonic:'UABDL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000000111000000000000),
    (mnemonic:'UABDL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110101000000111000000000000),

    (mnemonic:'UMLAL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110001000001000000000000000),
    (mnemonic:'UMLAL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000; value:%01101110001000001000000000000000),
       (mnemonic:'UMAXP';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5),  (ptype:pt_vreg_T_sizenot3; offset:16)); mask:%10111111001000001111110000000000;  value:%00101110001000001010010000000000),
 (mnemonic:'UMLAL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110011000001000000000000000),
    (mnemonic:'UMLAL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110011000001000000000000000),
    (mnemonic:'UMLAL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000; value:%00101110101000001000000000000000),
    (mnemonic:'UMLAL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000; value:%01101110101000001000000000000000),


    (mnemonic:'UMLSL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000;   value:%00101110001000001010000000000000),
    (mnemonic:'UMLSL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;   value:%01101110001000001010000000000000),
    (mnemonic:'UMLSL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000;   value:%00101110011000001010000000000000),
    (mnemonic:'UMLSL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;   value:%01101110011000001010000000000000),
    (mnemonic:'UMLSL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000;   value:%00101110101000001010000000000000),
    (mnemonic:'UMLSL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;   value:%01101110101000001010000000000000),

    (mnemonic:'UMULL'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_8B; offset: 5),  (ptype:pt_vreg_8B; offset: 5));  mask:%11111111111000001111110000000000;   value:%00101110001000001100000000000000),
    (mnemonic:'UMULL2'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_vreg_16B; offset: 5),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111000001111110000000000;   value:%01101110001000001100000000000000),
    (mnemonic:'UMULL'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_4H; offset: 5),  (ptype:pt_vreg_4H; offset: 5));  mask:%11111111111000001111110000000000;   value:%00101110011000001100000000000000),
    (mnemonic:'UMULL2'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_vreg_8H; offset: 5), (ptype:pt_vreg_8H; offset: 5));  mask:%11111111111000001111110000000000;   value:%01101110011000001100000000000000),
    (mnemonic:'UMULL'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_2S; offset: 5),  (ptype:pt_vreg_2S; offset: 5));  mask:%11111111111000001111110000000000;   value:%00101110101000001100000000000000),
    (mnemonic:'UMULL2'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_vreg_4S; offset: 5), (ptype:pt_vreg_4S; offset: 5));  mask:%11111111111000001111110000000000;   value:%01101110101000001100000000000000)

  );


  ArmInstructionsAdvSIMDTwoRegMisc: array of TOpcode=(
    (mnemonic:'REV64';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5)); mask:%10111111001111111111110000000000;  value:%00001110001000000000100000000000),
    (mnemonic:'REV16';  params:((ptype:pt_vreg_B_1bit; offset:0), (ptype:pt_vreg_B_1bit; offset:5));         mask:%10111111111111111111110000000000;  value:%00001110001000000000100000000000),

    (mnemonic:'SADDLP';  params:((ptype:pt_vreg_T2; offset:0), (ptype:pt_vreg_T; offset:5));                 mask:%10111111001111111111110000000000;  value:%00001110001000000010100000000000),
    (mnemonic:'SUQADD';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5));                  mask:%10111111001111111111110000000000;  value:%00001110001000000011100000000000),

    (mnemonic:'CLS';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5));   mask:%10111111001111111111110000000000;  value:%00001110001000000100100000000000),
    (mnemonic:'CNT';  params:((ptype:pt_vreg_B_1bit; offset:0), (ptype:pt_vreg_B_1bit; offset:5));           mask:%10111111111111111111110000000000;  value:%00001110001000000101100000000000),
    (mnemonic:'SADALP';  params:((ptype:pt_vreg_T2; offset:0), (ptype:pt_vreg_T; offset:5));                 mask:%10111111001111111111110000000000;  value:%00001110001000000110100000000000),

    (mnemonic:'SQABS';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5));                   mask:%10111111001111111111110000000000;  value:%00001110001000000111100000000000),
    (mnemonic:'CMGT'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),(ptype: pt_imm_val0)); mask:%10111111001111111111110000000000;  value:%00001110001000001000100000000000),
    (mnemonic:'CMEQ'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),(ptype: pt_imm_val0)); mask:%10111111001111111111110000000000;  value:%00001110001000001001100000000000),
    (mnemonic:'CMLT'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),(ptype: pt_imm_val0)); mask:%10111111001111111111110000000000;  value:%00001110001000001010100000000000),
    (mnemonic:'ABS';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5));                     mask:%10111111001111111111110000000000;  value:%00001110001000001011100000000000),

    (mnemonic:'XTN';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));           mask:%11111111001111111111110000000000;  value:%00001110001000010010100000000000),
    (mnemonic:'XTN2'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));           mask:%11111111001111111111110000000000;  value:%01001110001000010010100000000000),

    (mnemonic:'SQXTN';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));         mask:%11111111001111111111110000000000;  value:%00001110001000010100100000000000),
    (mnemonic:'SQXTN2'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));         mask:%11111111001111111111110000000000;  value:%01001110001000010100100000000000),

    (mnemonic:'FCVTN';  params:((ptype:pt_vreg_T_sizenot3or0 ; offset:0), (ptype:pt_vreg_4S; offset:5));     mask:%11111111111111111111110000000000;  value:%00001110001000010110100000000000),
    (mnemonic:'FCVTN';  params:((ptype:pt_vreg_T_sizenot3or0 ; offset:0), (ptype:pt_vreg_2D; offset:5));     mask:%11111111111111111111110000000000;  value:%00001110011000010110100000000000),
    (mnemonic:'FCVTN2';  params:((ptype:pt_vreg_T_sizenot3or0 ; offset:0), (ptype:pt_vreg_4S; offset:5));    mask:%11111111111111111111110000000000;  value:%01001110001000010110100000000000),
    (mnemonic:'FCVTN2';  params:((ptype:pt_vreg_T_sizenot3or0 ; offset:0), (ptype:pt_vreg_2D; offset:5));    mask:%11111111111111111111110000000000;  value:%01001110011000010110100000000000),

    (mnemonic:'FCVTL';  params:((ptype:pt_vreg_4S ; offset:0), (ptype:pt_vreg_T_sizenot3or0; offset:5));     mask:%11111111111111111111110000000000;  value:%00001110001000010111100000000000),
    (mnemonic:'FCVTL';  params:((ptype:pt_vreg_2D ; offset:0), (ptype:pt_vreg_T_sizenot3or0; offset:5));     mask:%11111111111111111111110000000000;  value:%00001110011000010111100000000000),
    (mnemonic:'FCVTL2'; params:((ptype:pt_vreg_4S ; offset:0), (ptype:pt_vreg_T_sizenot3or0; offset:5));     mask:%11111111111111111111110000000000;  value:%01001110001000010111100000000000),
    (mnemonic:'FCVTL2'; params:((ptype:pt_vreg_2D ; offset:0), (ptype:pt_vreg_T_sizenot3or0; offset:5));     mask:%11111111111111111111110000000000;  value:%01001110011000010111100000000000),

    (mnemonic:'FRINTN'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5));        mask:%10111111101111111111110000000000;  value:%00001110001000011000100000000000),
    (mnemonic:'FRINTM'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5));        mask:%10111111101111111111110000000000;  value:%00001110001000011001100000000000),

    (mnemonic:'FCVTNS'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5));        mask:%10111111101111111111110000000000;  value:%00001110001000011010100000000000),
    (mnemonic:'FCVTMS'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5));        mask:%10111111101111111111110000000000;  value:%00001110001000011011100000000000),
    (mnemonic:'FCVTAS'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5));        mask:%10111111101111111111110000000000;  value:%00001110001000011100100000000000),

    (mnemonic:'SCVTF';  params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5));        mask:%10111111101111111111110000000000;  value:%00001110001000011101100000000000),

    (mnemonic:'FCMGT';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5),(ptype:pt_imm_val0)); mask:%10111111101111111111110000000000; value:%00001110101000001100100000000000),
    (mnemonic:'FCMEQ';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5),(ptype:pt_imm_val0)); mask:%10111111101111111111110000000000; value:%00001110101000001101100000000000),
    (mnemonic:'FCMLT';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5),(ptype:pt_imm_val0)); mask:%10111111101111111111110000000000; value:%00001110101000001110100000000000),

    (mnemonic:'FABS';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5));              mask:%10111111101111111111110000000000;  value:%00001110101000001111100000000000),
    (mnemonic:'FPRINTP';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5));           mask:%10111111101111111111110000000000;  value:%00001110101000011000100000000000),
    (mnemonic:'FCVTPS';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5));            mask:%10111111101111111111110000000000;  value:%00001110101000011010100000000000),
    (mnemonic:'FCVTZS';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5));            mask:%10111111101111111111110000000000;  value:%00001110101000011011100000000000),

    (mnemonic:'URECPE';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5));            mask:%10111111111111111111110000000000;  value:%00001110101000011100100000000000),
    (mnemonic:'FRECPE';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_SD_2bit;offset:5));            mask:%10111111101111111111110000000000;  value:%00001110101000011101100000000000),


    (mnemonic:'REV32';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5));          mask:%10111111101111111111110000000000;  value:%00101110001000000000100000000000),
    (mnemonic:'UADDLP';  params:((ptype:pt_vreg_T2; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5));         mask:%10111111001111111111110000000000;  value:%00101110001000000010100000000000),
    (mnemonic:'USQADD';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5));                   mask:%10111111001111111111110000000000;  value:%00101110001000000011100000000000),
    (mnemonic:'CLZ';  params:((ptype:pt_vreg_T_sizenot3; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5));    mask:%10111111001111111111110000000000;  value:%00101110001000000100100000000000),
    (mnemonic:'UADALP';  params:((ptype:pt_vreg_T2; offset:0), (ptype:pt_vreg_T_sizenot3; offset:5));         mask:%10111111001111111111110000000000;  value:%00101110001000000110100000000000),
    (mnemonic:'SQNEG';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5));                    mask:%10111111001111111111110000000000;  value:%00101110001000000111100000000000),

    (mnemonic:'CMGE'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),(ptype: pt_imm_val0)); mask:%10111111001111111111110000000000;  value:%00101110001000001000100000000000),
    (mnemonic:'CMLE'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5),(ptype: pt_imm_val0)); mask:%10111111001111111111110000000000;  value:%00101110001000001001100000000000),

    (mnemonic:'NEG';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T; offset:5));                      mask:%10111111001111111111110000000000;  value:%00101110001000001011100000000000),

    (mnemonic:'SQXTN';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));         mask:%11111111001111111111110000000000;  value:%00101110001000010010100000000000),
    (mnemonic:'SQXTN2'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));         mask:%11111111001111111111110000000000;  value:%01101110001000010010100000000000),

    (mnemonic:'SHLL';  params:((ptype:pt_vreg_T2_AssumeQ1; offset:0), (ptype:pt_vreg_T; offset:5));          mask:%11111111001111111111110000000000;  value:%00101110001000010011100000000000),
    (mnemonic:'SHLL2'; params:((ptype:pt_vreg_T2_AssumeQ1; offset:0), (ptype:pt_vreg_T; offset:5));          mask:%11111111001111111111110000000000;  value:%01101110001000010011100000000000),

    (mnemonic:'UQXTN';  params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));         mask:%11111111001111111111110000000000;  value:%00101110001000010011100000000000),
    (mnemonic:'UQXTN2'; params:((ptype:pt_vreg_T; offset:0), (ptype:pt_vreg_T2_AssumeQ1; offset:5));         mask:%11111111001111111111110000000000;  value:%01101110001000010011100000000000),

    (mnemonic:'FCVTN';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                  mask:%11111111111111111111110000000000;  value:%00101110011000010110100000000000),
    (mnemonic:'FCVTN2';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                 mask:%11111111111111111111110000000000;  value:%01101110011000010110100000000000),

    (mnemonic:'FRINTA';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                 mask:%10111111101111111111110000000000;  value:%00101110011000011000100000000000),
    (mnemonic:'FRINTX';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                 mask:%10111111101111111111110000000000;  value:%00101110001000011001100000000000),
    (mnemonic:'FCVTNU';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                 mask:%10111111101111111111110000000000;  value:%00101110001000011010100000000000),
    (mnemonic:'FCVTMU';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                 mask:%10111111101111111111110000000000;  value:%00101110001000011011100000000000),
    (mnemonic:'FCVTAU';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                 mask:%10111111101111111111110000000000;  value:%00101110001000011100100000000000),
    (mnemonic:'UCVTF';params:((ptype:pt_vreg_SD_2bit;offset:0),(ptype:pt_vreg_2D;offset:5));                  mask:%10111111101111111111110000000000;  value:%00101110001000011101100000000000),


    (mnemonic:'NOT';  params:((ptype:pt_vreg_B_1bit; offset:0), (ptype:pt_vreg_B_1bit; offset:5));           mask:%10111111111111111111110000000000;  value:%00101110001000000101100000000000),

    (mnemonic:'FCMGE'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000001100100000000000),
    (mnemonic:'FCMLE'; params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000001101100000000000),
    (mnemonic:'FNEG';  params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000001111100000000000),
    (mnemonic:'FRINTI';params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000011001100000000000),
    (mnemonic:'FCVTPU';params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000011010100000000000),
    (mnemonic:'FCVTZU';params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000011011100000000000),

    (mnemonic:'URSQRTE';params:((ptype:pt_vreg_2S;offset:0),(ptype:pt_vreg_2S;offset:5)); mask:%11111111111111111111110000000000;  value:%00101110101000011100100000000000),
    (mnemonic:'URSQRTE';params:((ptype:pt_vreg_4S;offset:0),(ptype:pt_vreg_4S;offset:5)); mask:%11111111111111111111110000000000;  value:%01101110101000011100100000000000),

    (mnemonic:'FRSQRTE';params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000011101100000000000),
    (mnemonic:'FSQRT';  params:((ptype:pt_vreg_SD_2bit; offset:0), (ptype:pt_vreg_SD_2bit; offset:5),(ptype: pt_imm_val0)); mask:%10111111101111111111110000000000;  value:%00101110101000011111100000000000)

  );

  ArmInstructionsAdvSIMDAcrossLanes: array of TOpcode=(
    (mnemonic:'SADDLV'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110001100000011100000000000),
    (mnemonic:'SADDLV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110011100000011100000000000),
    (mnemonic:'SADDLV'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110101100000011100000000000),

    (mnemonic:'SMAXV'; params:((ptype:pt_breg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110001100001010100000000000),
    (mnemonic:'SMAXV'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110011100001010100000000000),
    (mnemonic:'SMAXV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110101100001010100000000000),

    (mnemonic:'SMINV'; params:((ptype:pt_breg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110001100011010100000000000),
    (mnemonic:'SMINV'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110011100011010100000000000),
    (mnemonic:'SMINV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110101100011010100000000000),

    (mnemonic:'ADDV'; params:((ptype:pt_breg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110001100011011100000000000),
    (mnemonic:'ADDV'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110011100011011100000000000),
    (mnemonic:'ADDV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00001110101100011011100000000000),

    (mnemonic:'UADDLV'; params:((ptype:pt_breg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110001100000011100000000000),
    (mnemonic:'UADDLV'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110011100000011100000000000),
    (mnemonic:'UADDLV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110101100000011100000000000),

    (mnemonic:'UMAXV'; params:((ptype:pt_breg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110001100001010100000000000),
    (mnemonic:'UMAXV'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110011100001010100000000000),
    (mnemonic:'UMAXV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110101100001010100000000000),

    (mnemonic:'UMINV'; params:((ptype:pt_breg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110001100011010100000000000),
    (mnemonic:'UMINV'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110011100011010100000000000),
    (mnemonic:'UMINV'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000) );    mask:%10111111111111111111110000000000;  value:%00101110101100011010100000000000),

    (mnemonic:'FMAXNVM'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_4S; offset: 5)); mask:%11111111111111111111110000000000;  value:%01001110001100001100100000000000),
    (mnemonic:'FMAXV';   params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_4S; offset: 5)); mask:%11111111111111111111110000000000;  value:%01101110001100001111100000000000),
    (mnemonic:'FMINNVM'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_4S; offset: 5)); mask:%11111111111111111111110000000000;  value:%01101110101100001100100000000000),
    (mnemonic:'FMINV';   params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_4S; offset: 5)); mask:%11111111111111111111110000000000;  value:%01101110101100001111100000000000)
  );

  ArmInstructionsAdvSIMDCopy: array of TOpcode=(
    (mnemonic:'DUP'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_B_Index; offset: 5; maxval:$f; extra:17));  mask:%11111111111000011111110000000000; value:%00001110000000010000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_B_Index; offset: 5; maxval:$f; extra:17)); mask:%11111111111000011111110000000000; value:%01001110000000010000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_H_Index; offset: 5; maxval:$7; extra:18));  mask:%11111111111000111111110000000000; value:%00001110000000100000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_H_Index; offset: 5; maxval:$7; extra:18));  mask:%11111111111000111111110000000000; value:%01001110000000100000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_S_Index; offset: 5; maxval:$3; extra:19));  mask:%11111111111001111111110000000000; value:%00001110000001000000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_S_Index; offset: 5; maxval:$3; extra:19));  mask:%11111111111001111111110000000000; value:%01001110000001000000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_D_Index; offset: 5; maxval:$1; extra:20));  mask:%11111111111011111111110000000000; value:%01001110000010000000010000000000),

    (mnemonic:'DUP'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_wreg; offset: 5));  mask:%11111111111000011111110000000000; value:%00001110000000010000110000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_wreg; offset:5));  mask:%11111111111000011111110000000000; value:%01001110000000010000110000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_wreg; offset: 5));  mask:%11111111111000111111110000000000; value:%00001110000000100000110000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_wreg; offset: 5));  mask:%11111111111000111111110000000000; value:%01001110000000100000110000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_wreg; offset: 5));  mask:%11111111111001111111110000000000; value:%00001110000001000000110000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_wreg; offset: 5));  mask:%11111111111001111111110000000000; value:%01001110000001000000110000000000),
    (mnemonic:'DUP'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_xreg; offset: 5));  mask:%11111111111011111111110000000000; value:%01001110000010000000110000000000),

    (mnemonic:'SMOV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_vreg_B_Index; offset: 5; maxval:$f; extra:17));  mask:%11111111111000011111110000000000; value:%00001110000000010010110000000000),
    (mnemonic:'SMOV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_vreg_B_Index; offset: 5; maxval:$f; extra:17));  mask:%11111111111000011111110000000000; value:%01001110000000010010110000000000),
    (mnemonic:'SMOV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_vreg_H_Index; offset: 5; maxval:$7; extra:18));  mask:%11111111111000111111110000000000; value:%00001110000000100010110000000000),
    (mnemonic:'SMOV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_vreg_H_Index; offset: 5; maxval:$7; extra:18));  mask:%11111111111000111111110000000000; value:%01001110000000100010110000000000),
    (mnemonic:'SMOV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_vreg_S_Index; offset: 5; maxval:$3; extra:19));  mask:%11111111111001111111110000000000; value:%01001110000001000010110000000000),

    (mnemonic:'SMOV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_vreg_B_Index; offset: 5; maxval:$f; extra:17));  mask:%11111111111000011111110000000000; value:%00001110000000010011110000000000),
    (mnemonic:'SMOV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_vreg_H_Index; offset: 5; maxval:$7; extra:18));  mask:%11111111111000111111110000000000; value:%00001110000000100011110000000000),
    (mnemonic:'SMOV'; params:((ptype:pt_wreg; offset: 0),(ptype:pt_vreg_S_Index; offset: 5; maxval:$3; extra:19));  mask:%11111111111001111111110000000000; value:%00001110000001000011110000000000),
    (mnemonic:'SMOV'; params:((ptype:pt_xreg; offset: 0),(ptype:pt_vreg_S_Index; offset: 5; maxval:$1; extra:20));  mask:%11111111111011111111110000000000; value:%00001110000010000011110000000000),

    (mnemonic:'INS'; params:((ptype:pt_vreg_B_Index; offset: 0; maxval:$f; extra:17), (ptype:pt_wreg; offset: 5));  mask:%11111111111000011111110000000000; value:%01001110000000010001110000000000),
    (mnemonic:'INS'; params:((ptype:pt_vreg_H_Index; offset: 0; maxval:$7; extra:18), (ptype:pt_wreg; offset: 5));  mask:%11111111111000111111110000000000; value:%01001110000000100001110000000000),
    (mnemonic:'INS'; params:((ptype:pt_vreg_S_Index; offset: 0; maxval:$3; extra:19), (ptype:pt_wreg; offset: 5));  mask:%11111111111001111111110000000000; value:%01001110000001000001110000000000),
    (mnemonic:'INS'; params:((ptype:pt_vreg_d_Index; offset: 0; maxval:$1; extra:20), (ptype:pt_xreg; offset: 5));  mask:%11111111111011111111110000000000; value:%01001110000010000001110000000000),


    (mnemonic:'INS'; params:((ptype:pt_vreg_B_Index; offset: 0; maxval:$f; extra:17), (ptype:pt_vreg_B_Index; offset: 5; maxval:$f; extra:11));  mask:%11111111111000011000010000000000; value:%01101110000000010000010000000000),
    (mnemonic:'INS'; params:((ptype:pt_vreg_H_Index; offset: 0; maxval:$7; extra:18), (ptype:pt_vreg_H_Index; offset: 5; maxval:$7; extra:12));  mask:%11111111111000111000010000000000; value:%01101110000000100000010000000000),
    (mnemonic:'INS'; params:((ptype:pt_vreg_S_Index; offset: 0; maxval:$3; extra:19), (ptype:pt_vreg_S_Index; offset: 5; maxval:$3; extra:13));  mask:%11111111111001111000010000000000; value:%01101110000001000000010000000000),
    (mnemonic:'INS'; params:((ptype:pt_vreg_D_Index; offset: 0; maxval:$1; extra:20), (ptype:pt_vreg_S_Index; offset: 5; maxval:$1; extra:14));  mask:%11111111111011111000010000000000; value:%01101110000010000000010000000000)



  );

  ArmInstructionsAdvSIMDVectorXIndexedElement: array of TOpcode=(
    (mnemonic:'SMLAL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));    mask:%11111111000000001111010000000000; value:%00001111000000000010000000000000),
    (mnemonic:'SMLAL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));   mask:%11111111000000001111010000000000; value:%01001111000000000010000000000000),

    (mnemonic:'SQDMLAL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));  mask:%11111111000000001111010000000000; value:%00001111000000000011000000000000),
    (mnemonic:'SQDMLAL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16)); mask:%11111111000000001111010000000000; value:%01001111000000000011000000000000),

    (mnemonic:'SMLSL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));    mask:%11111111000000001111010000000000; value:%00001111000000000110000000000000),
    (mnemonic:'SMLSL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));   mask:%11111111000000001111010000000000; value:%00001111000000000110000000000000),

    (mnemonic:'SQDMLSL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));  mask:%11111111000000001111010000000000; value:%00001111000000000111000000000000),
    (mnemonic:'SQDMLSL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16)); mask:%11111111000000001111010000000000; value:%01001111000000000111000000000000),

    (mnemonic:'MUL'; params:((ptype:pt_vreg_T_sizenot3or0; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));mask:%10111111000000001111010000000000; value:%00001111000000001000000000000000),

    (mnemonic:'SMULL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));    mask:%11111111000000001111010000000000; value:%00001111000000001010000000000000),
    (mnemonic:'SMULL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));   mask:%11111111000000001111010000000000; value:%01001111000000001010000000000000),

    (mnemonic:'SQDMULL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));  mask:%11111111000000001111010000000000; value:%00001111000000001011000000000000),
    (mnemonic:'SQDMULL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16)); mask:%11111111000000001111010000000000; value:%00001111000000001011000000000000),

    (mnemonic:'SQDMULH'; params:((ptype:pt_vreg_T_sizenot3or0; offset: 0),(ptype:pt_vreg_T_sizenot3or0;offset:5),(ptype:pt_vreg_HS_HLMIndex;offset:16));mask:%10111111000000001111010000000000; value:%00001111000000001100000000000000),
    (mnemonic:'SQRDMULH';params:((ptype:pt_vreg_T_sizenot3or0; offset: 0),(ptype:pt_vreg_T_sizenot3or0;offset:5),(ptype:pt_vreg_HS_HLMIndex;offset:16));mask:%10111111000000001111010000000000; value:%00001111000000001101000000000000),

    (mnemonic:'FMLA'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_SD_2bit; offset: 5),(ptype:pt_vreg_SD_HLIndex;offset: 16));mask:%10111111100000001111010000000000; value:%00001111100000000001000000000000),
    (mnemonic:'FMLS'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_SD_2bit; offset: 5),(ptype:pt_vreg_SD_HLIndex;offset: 16));mask:%10111111100000001111010000000000; value:%00001111100000000101000000000000),
    (mnemonic:'FMUL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_SD_2bit; offset: 5),(ptype:pt_vreg_SD_HLIndex;offset: 16));mask:%10111111100000001111010000000000; value:%00001111100000001001000000000000),

    (mnemonic:'MLA'; params:((ptype:pt_vreg_T_sizenot3or0; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));mask:%10111111000000001111010000000000; value:%00101111000000000000000000000000),

    (mnemonic:'UMLAL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));    mask:%11111111000000001111010000000000; value:%00101111000000000010000000000000),
    (mnemonic:'UMLAL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));   mask:%11111111000000001111010000000000; value:%01101111000000000010000000000000),

    (mnemonic:'MLS'; params:((ptype:pt_vreg_T_sizenot3or0; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));mask:%10111111000000001111010000000000; value:%00101111000000000100000000000000),

    (mnemonic:'UMLSL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));    mask:%11111111000000001111010000000000; value:%00101111000000000110000000000000),
    (mnemonic:'UMLSL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));   mask:%11111111000000001111010000000000; value:%01101111000000000110000000000000),


    (mnemonic:'UMULL'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));    mask:%11111111000000001111010000000000; value:%00101111000000001010000000000000),
    (mnemonic:'UMULL2'; params:((ptype:pt_vreg_SD_2bit; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));   mask:%11111111000000001111010000000000; value:%01101111000000001010000000000000),

    (mnemonic:'FMULX'; params:((ptype:pt_vreg_T_sizenot3or0; offset: 0),(ptype:pt_vreg_T_sizenot3or0; offset: 5),(ptype:pt_vreg_HS_HLMIndex; offset: 16));mask:%10111111000000001111010000000000; value:%00101111100000001001000000000000)
  );


  ArmInstructionsAdvSIMDModifiedImmediate: array of TOpcode=(
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_8B; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%00001111000000001110010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%01001111000000001110010000000000),

    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%00001111000000001000010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%01001111000000001000010000000000),

    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));  mask:%11111111111110001111110000000000; value:%00001111000000001010010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));  mask:%11111111111110001111110000000000; value:%01001111000000001010010000000000),

    (mnemonic:'MOVI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%00001111000000000000010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%01001111000000000000010000000000),//0000
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%00001111000000000010010000000000), //0010
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%01001111000000000010010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%00001111000000000100010000000000), //0100
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%01001111000000000100010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 24));  mask:%11111111111110001111110000000000; value:%00001111000000000110010000000000), //0110
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 24));  mask:%11111111111110001111110000000000; value:%01001111000000000110010000000000),

    //shifting ones
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 8));  mask:%11111111111110001111110000000000; value:%00001111000000001100010000000000), //1100
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 8));  mask:%11111111111110001111110000000000; value:%01001111000000001100010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%00001111000000001101010000000000), //1101
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%01001111000000001101010000000000),

    (mnemonic:'MOVI'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_imm2_8; offset:%00000000000001110000001111100000),    (ptype:pt_mslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%00101111000000001110010000000000),
    (mnemonic:'MOVI'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_imm2_8; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%01101111000000001110010000000000),

    //orr
    (mnemonic:'ORR'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%00001111000000001001010000000000), //q=0 1001
    (mnemonic:'ORR'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%01001111000000001001010000000000), //q=1 1001

    (mnemonic:'ORR'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 8));  mask:%11111111111110001111110000000000; value:%00001111000000001011010000000000), //q=0 1011
    (mnemonic:'ORR'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 8));  mask:%11111111111110001111110000000000; value:%01001111000000001011010000000000), //q=0 1011

    (mnemonic:'ORR'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%00001111000000000001010000000000), //q=0 0001
    (mnemonic:'ORR'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%01001111000000000001010000000000), //q=1 0001
    (mnemonic:'ORR'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 8));  mask:%11111111111110001111110000000000;  value:%00001111000000000011010000000000), //q=0 0011
    (mnemonic:'ORR'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 8));  mask:%11111111111110001111110000000000;  value:%01001111000000000011010000000000), //q=1 0011
    (mnemonic:'ORR'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%00001111000000000101010000000000), //q=0 0101
    (mnemonic:'ORR'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%01001111000000000101010000000000), //q=1 0101
    (mnemonic:'ORR'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 24));  mask:%11111111111110001111110000000000; value:%00001111000000000111010000000000), //q=0 0111
    (mnemonic:'ORR'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000),(ptype:pt_lslSpecific; offset: 24));  mask:%11111111111110001111110000000000; value:%01001111000000000111010000000000), //q=1 0111

    (mnemonic:'FMOV'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2_8; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%00001111000000001111010000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2_8; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%01001111000000001111010000000000),
    (mnemonic:'FMOV'; params:((ptype:pt_vreg_2D; offset: 0), (ptype:pt_imm2_8; offset:%00000000000001110000001111100000));  mask:%11111111111110001111110000000000; value:%01101111000000001111010000000000),


    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                      mask:%11111111111110001111110000000000; value:%00101111000000001000010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                      mask:%11111111111110001111110000000000; value:%01101111000000001000010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%00101111000000001010010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%01101111000000001010010000000000),

    (mnemonic:'MVNI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                      mask:%11111111111110001111110000000000; value:%00101111000000000000010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                      mask:%11111111111110001111110000000000; value:%01101111000000000000010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%00101111000000000010010000000000), //32 bit 0010
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%01101111000000000010010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%00101111000000000100010000000000), //32 bit 0100
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%01101111000000000100010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 24));  mask:%11111111111110001111110000000000; value:%00101111000000000110010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 24));  mask:%11111111111110001111110000000000; value:%01101111000000000110010000000000),

    (mnemonic:'MVNI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%00101111000000001100010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 8));   mask:%11111111111110001111110000000000; value:%01101111000000001100010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%00101111000000001101010000000000),
    (mnemonic:'MVNI'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_mslSpecific; offset: 16));  mask:%11111111111110001111110000000000; value:%01101111000000001101010000000000),


    (mnemonic:'BIC'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                       mask:%11111111111110001111110000000000; value:%00101111000000001001010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                       mask:%11111111111110001111110000000000; value:%01101111000000001001010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_4H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));    mask:%11111111111110001111110000000000; value:%00101111000000001011010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_8H; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));    mask:%11111111111110001111110000000000; value:%01101111000000001011010000000000),

    (mnemonic:'BIC'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                       mask:%11111111111110001111110000000000; value:%00101111000000000001010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000));                                       mask:%11111111111110001111110000000000; value:%01101111000000000001010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));    mask:%11111111111110001111110000000000; value:%00101111000000000011010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 8));    mask:%11111111111110001111110000000000; value:%01101111000000000011010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 16));   mask:%11111111111110001111110000000000; value:%00101111000000000101010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 16));   mask:%11111111111110001111110000000000; value:%01101111000000000101010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_2S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 24));   mask:%11111111111110001111110000000000; value:%00101111000000000111010000000000),
    (mnemonic:'BIC'; params:((ptype:pt_vreg_4S; offset: 0), (ptype:pt_imm2; offset:%00000000000001110000001111100000), (ptype:pt_lslSpecific; offset: 24));   mask:%11111111111110001111110000000000; value:%01101111000000000111010000000000)

  );

  ArmInstructionsAdvSIMDShiftByImmediate: array of TOpcode=(
    (mnemonic:'SSHR'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%00001111000010000000010000000000),
    (mnemonic:'SSHR'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%01001111000010000000010000000000),
    (mnemonic:'SSHR'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%00001111000100000000010000000000),
    (mnemonic:'SSHR'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%01001111000100000000010000000000),
    (mnemonic:'SSHR'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00001111001000000000010000000000),
    (mnemonic:'SSHR'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01001111001000000000010000000000),
    (mnemonic:'SSHR'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01001111010000000000010000000000),

    (mnemonic:'SSRA'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%00001111000010000000010000000000),
    (mnemonic:'SSRA'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%01001111000010000000010000000000),
    (mnemonic:'SSRA'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%00001111000100000000010000000000),
    (mnemonic:'SSRA'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%01001111000100000000010000000000),
    (mnemonic:'SSRA'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00001111001000000000010000000000),
    (mnemonic:'SSRA'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01001111001000000000010000000000),
    (mnemonic:'SSRA'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01001111010000000000010000000000),

    (mnemonic:'SRSHR'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%00001111000010000010010000000000),
    (mnemonic:'SRSHR'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%01001111000010000010010000000000),
    (mnemonic:'SRSHR'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%00001111000100000010010000000000),
    (mnemonic:'SRSHR'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%01001111000100000010010000000000),
    (mnemonic:'SRSHR'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%00001111001000000010010000000000),
    (mnemonic:'SRSHR'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%01001111001000000010010000000000),
    (mnemonic:'SRSHR'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));mask:%11111111110000001111110000000000; value:%01001111010000000010010000000000),

    (mnemonic:'SRSRA'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%00001111000010000011010000000000),
    (mnemonic:'SRSRA'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%01001111000010000011010000000000),
    (mnemonic:'SRSRA'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%00001111000100000011010000000000),
    (mnemonic:'SRSRA'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%01001111000100000011010000000000),
    (mnemonic:'SRSRA'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%00001111001000000011010000000000),
    (mnemonic:'SRSRA'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%01001111001000000011010000000000),
    (mnemonic:'SRSRA'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));mask:%11111111110000001111110000000000; value:%01001111010000000011010000000000),

    (mnemonic:'SHL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%00001111000010000101010000000000),
    (mnemonic:'SHL'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%01001111000010000101010000000000),
    (mnemonic:'SHL'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%00001111000100000101010000000000),
    (mnemonic:'SHL'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%01001111000100000101010000000000),
    (mnemonic:'SHL'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%00001111001000000101010000000000),
    (mnemonic:'SHL'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%01001111001000000101010000000000),
    (mnemonic:'SHL'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:64));mask:%11111111110000001111110000000000;   value:%01001111010000000101010000000000),

    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000; value:%00001111000010000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000; value:%01001111000010000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;value:%00001111000100000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;value:%01001111000100000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;value:%00001111001000000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;value:%01001111001000000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:64));mask:%11111111110000001111110000000000; value:%01001111010000000111010000000000),

    (mnemonic:'SHRN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;  value:%00001111000010000101010000000000),
    (mnemonic:'SHRN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;  value:%01001111000010000101010000000000),
    (mnemonic:'SHRN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;  value:%00001111000100000101010000000000),
    (mnemonic:'SHRN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;  value:%01001111000100000101010000000000),
    (mnemonic:'SHRN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;  value:%00001111001000000101010000000000),
    (mnemonic:'SHRN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;  value:%01001111001000000101010000000000),

    (mnemonic:'RSHRN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;  value:%00001111000010001000110000000000),
    (mnemonic:'RSHRN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;  value:%01001111000010001000110000000000),
    (mnemonic:'RSHRN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;  value:%00001111000100001000110000000000),
    (mnemonic:'RSHRN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;  value:%01001111000100001000110000000000),
    (mnemonic:'RSHRN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;  value:%00001111001000001000110000000000),
    (mnemonic:'RSHRN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;  value:%01001111001000001000110000000000),


    (mnemonic:'SQSHRN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;  value:%00001111000010001001010000000000),
    (mnemonic:'SQSHRN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;  value:%01001111000010001001010000000000),
    (mnemonic:'SQSHRN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;  value:%00001111000100001001010000000000),
    (mnemonic:'SQSHRN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;  value:%01001111000100001001010000000000),
    (mnemonic:'SQSHRN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;  value:%00001111001000001001010000000000),
    (mnemonic:'SQSHRN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;  value:%01001111001000001001010000000000),

    (mnemonic:'SQRSHRN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%00001111000010001001110000000000),
    (mnemonic:'SQRSHRN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%01001111000010001001110000000000),
    (mnemonic:'SQRSHRN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;    value:%00001111000100001001110000000000),
    (mnemonic:'SQRSHRN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;    value:%01001111000100001001110000000000),
    (mnemonic:'SQRSHRN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;    value:%00001111001000001001110000000000),
    (mnemonic:'SQRSHRN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;value:%01001111001000001001110000000000),

    (mnemonic:'SCVTF'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00001111001000001110010000000000),
    (mnemonic:'SCVTF'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01001111001000001110010000000000),
    (mnemonic:'SCVTF'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01001111010000001110010000000000),

    (mnemonic:'FCVTZS'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00001111001000001111110000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01001111001000001111110000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01001111010000001111110000000000),


    (mnemonic:'USHR'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%00101111000010000000010000000000),
    (mnemonic:'USHR'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%01101111000010000000010000000000),
    (mnemonic:'USHR'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%00101111000100000000010000000000),
    (mnemonic:'USHR'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%01101111000100000000010000000000),
    (mnemonic:'USHR'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00101111001000000000010000000000),
    (mnemonic:'USHR'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01101111001000000000010000000000),
    (mnemonic:'USHR'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01101111010000000000010000000000),

    (mnemonic:'USRA'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%00101111000010000000010000000000),
    (mnemonic:'USRA'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%01101111000010000000010000000000),
    (mnemonic:'USRA'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%00101111000100000000010000000000),
    (mnemonic:'USRA'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%01101111000100000000010000000000),
    (mnemonic:'USRA'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00101111001000000000010000000000),
    (mnemonic:'USRA'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01101111001000000000010000000000),
    (mnemonic:'USRA'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01101111010000000000010000000000),

    (mnemonic:'URSHR'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%00101111000010000010010000000000),
    (mnemonic:'URSHR'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%01101111000010000010010000000000),
    (mnemonic:'URSHR'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%00101111000100000010010000000000),
    (mnemonic:'URSHR'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%01101111000100000010010000000000),
    (mnemonic:'URSHR'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%00101111001000000010010000000000),
    (mnemonic:'URSHR'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%01101111001000000010010000000000),
    (mnemonic:'URSHR'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));mask:%11111111110000001111110000000000; value:%01101111010000000010010000000000),

    (mnemonic:'URSRA'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%00101111000010000011010000000000),
    (mnemonic:'URSRA'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%01101111000010000011010000000000),
    (mnemonic:'URSRA'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%00101111000100000011010000000000),
    (mnemonic:'URSRA'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%01101111000100000011010000000000),
    (mnemonic:'URSRA'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%00101111001000000011010000000000),
    (mnemonic:'URSRA'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%01101111001000000011010000000000),
    (mnemonic:'URSRA'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));mask:%11111111110000001111110000000000; value:%01101111010000000011010000000000),


    (mnemonic:'SRI'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%00101111000010000100010000000000),
    (mnemonic:'SRI'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%01101111000010000100010000000000),
    (mnemonic:'SRI'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%00101111000100000100010000000000),
    (mnemonic:'SRI'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%01101111000100000100010000000000),
    (mnemonic:'SRI'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%00101111001000000100010000000000),
    (mnemonic:'SRI'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%01101111001000000100010000000000),
    (mnemonic:'SRI'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));mask:%11111111110000001111110000000000; value:%01101111010000000100010000000000),

    (mnemonic:'SLI'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%00101111000010000101010000000000),
    (mnemonic:'SLI'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%01101111000010000101010000000000),
    (mnemonic:'SLI'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%00101111000100000101010000000000),
    (mnemonic:'SLI'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%01101111000100000101010000000000),
    (mnemonic:'SLI'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%00101111001000000101010000000000),
    (mnemonic:'SLI'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%01101111001000000101010000000000),
    (mnemonic:'SLI'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:64));mask:%11111111110000001111110000000000;   value:%01101111010000000101010000000000),

    (mnemonic:'SQSHLU'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%00101111000010000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%01101111000010000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%00101111000100000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%01101111000100000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%00101111001000000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%01101111001000000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:64));mask:%11111111110000001111110000000000;   value:%01101111010000000110010000000000),

    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5; maxval:$f; extra:17),   (ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%00101111000010000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5; maxval:$f; extra:17),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8)); mask:%11111111111110001111110000000000;   value:%01101111000010000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%00101111000100000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000;  value:%01101111000100000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%00101111001000000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000;  value:%01101111001000000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:64));mask:%11111111110000001111110000000000;   value:%01101111010000000111010000000000),


    (mnemonic:'SQSHRUN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%00101111000010001000010000000000),
    (mnemonic:'SQSHRUN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%01101111000010001000010000000000),
    (mnemonic:'SQSHRUN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;    value:%00101111000100001000010000000000),
    (mnemonic:'SQSHRUN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;    value:%01101111000100001000010000000000),
    (mnemonic:'SQSHRUN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;    value:%00101111001000001000010000000000),
    (mnemonic:'SQSHRUN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;    value:%01101111001000001000010000000000),

    (mnemonic:'SQRSHRUN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%00101111000010001000110000000000),
    (mnemonic:'SQRSHRUN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%01101111000010001000110000000000),
    (mnemonic:'SQRSHRUN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;    value:%00101111000100001000110000000000),
    (mnemonic:'SQRSHRUN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;    value:%01101111000100001000110000000000),
    (mnemonic:'SQRSHRUN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;    value:%00101111001000001000110000000000),
    (mnemonic:'SQRSHRUN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;    value:%01101111001000001000110000000000),

    (mnemonic:'UQSHRN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%00101111000010001001010000000000),
    (mnemonic:'UQSHRN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%01101111000010001001010000000000),
    (mnemonic:'UQSHRN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;    value:%00101111000100001001010000000000),
    (mnemonic:'UQSHRN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;    value:%01101111000100001001010000000000),
    (mnemonic:'UQSHRN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;    value:%00101111001000001001010000000000),
    (mnemonic:'UQSHRN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;    value:%01101111001000001001010000000000),

    (mnemonic:'UQRSHRN'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%00101111000010001001110000000000),
    (mnemonic:'UQRSHRN2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%01101111000010001001110000000000),
    (mnemonic:'UQRSHRN'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;    value:%00101111000100001001110000000000),
    (mnemonic:'UQRSHRN2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;    value:%01101111000100001001110000000000),
    (mnemonic:'UQRSHRN'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;    value:%00101111001000001001110000000000),
    (mnemonic:'UQRSHRN2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;    value:%01101111001000001001110000000000),

    (mnemonic:'USHLL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),   (ptype:pt_immminx; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%00101111000010001010010000000000),
    (mnemonic:'USHLL2'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8H; offset: 5; maxval:$f; extra:17),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;    value:%01101111000010001010010000000000),
    (mnemonic:'USHLL'; params:((ptype:pt_vreg_4H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;    value:%00101111000100001010010000000000),
    (mnemonic:'USHLL2'; params:((ptype:pt_vreg_8H; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$7; extra:18),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000;    value:%01101111000100001010010000000000),
    (mnemonic:'USHLL'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;    value:%00101111001000001010010000000000),
    (mnemonic:'USHLL2'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$3; extra:19),  (ptype:pt_immminx; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000;    value:%01101111001000001010010000000000),


    (mnemonic:'UCVTF'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00101111001000001110010000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01101111001000001110010000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01101111010000001110010000000000),


    (mnemonic:'FCVTZU'; params:((ptype:pt_vreg_2S; offset: 0),(ptype:pt_vreg_2S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%00101111001000001111110000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_vreg_4S; offset: 0),(ptype:pt_vreg_4S; offset: 5; maxval:$3; extra:19),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01101111001000001111110000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_vreg_2D; offset: 0),(ptype:pt_vreg_2D; offset: 5; maxval:$1; extra:20),  (ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01101111010000001111110000000000)


  );


  ArmInstructionsAdvSIMDTBLTBX: array of TOpcode=(
   (mnemonic:'TBL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:1; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000000000000000000),
   (mnemonic:'TBL'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:1; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000000000000000000),

   (mnemonic:'TBL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:2; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000010000000000000),
   (mnemonic:'TBL'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:2; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000010000000000000),

   (mnemonic:'TBL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:3; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000100000000000000),
   (mnemonic:'TBL'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:3; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000100000000000000),

   (mnemonic:'TBL'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:4; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000110000000000000),
   (mnemonic:'TBL'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:4; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000110000000000000),

   (mnemonic:'TBX'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:1; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000001000000000000),
   (mnemonic:'TBX'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:1; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000001000000000000),

   (mnemonic:'TBX'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:2; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000011000000000000),
   (mnemonic:'TBX'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:2; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000011000000000000),

   (mnemonic:'TBX'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:3; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000101000000000000),
   (mnemonic:'TBX'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:3; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000101000000000000),

   (mnemonic:'TBX'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:4; extra:%100),(ptype:pt_vreg_8B; offset: 16) );    mask:%11111111111000001111110000000000;  value:%00001110000000000111000000000000),
   (mnemonic:'TBX'; params:((ptype:pt_vreg_16b; offset: 0),(ptype:pt_reglist_vector_specificsize; offset: 5; maxval:4; extra:%100),(ptype:pt_vreg_16B; offset: 16) );  mask:%11111111111000001111110000000000;  value:%01001110000000000111000000000000)


  );
  ArmInstructionsAdvSIMDZIPUNZTRN: array of TOpcode=(
    (mnemonic:'UZP1'; params:((ptype:pt_vreg_T; offset: 0;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 16;maxval:$1f; extra:%01000000110000000000000000000000));  mask:%10111111001000001111110000000000;  value:%00001110000000000001100000000000),
    (mnemonic:'TRN1'; params:((ptype:pt_vreg_T; offset: 0;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 16;maxval:$1f; extra:%01000000110000000000000000000000));  mask:%10111111001000001111110000000000;  value:%00001110000000000010100000000000),
    (mnemonic:'ZIP1'; params:((ptype:pt_vreg_T; offset: 0;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 16;maxval:$1f; extra:%01000000110000000000000000000000));  mask:%10111111001000001111110000000000;  value:%00001110000000000011100000000000),

    (mnemonic:'UZP2'; params:((ptype:pt_vreg_T; offset: 0;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 16;maxval:$1f; extra:%01000000110000000000000000000000));  mask:%10111111001000001111110000000000;  value:%00001110000000000101100000000000),
    (mnemonic:'TRN2'; params:((ptype:pt_vreg_T; offset: 0;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 16;maxval:$1f; extra:%01000000110000000000000000000000));  mask:%10111111001000001111110000000000;  value:%00001110000000000110100000000000),
    (mnemonic:'ZIP2'; params:((ptype:pt_vreg_T; offset: 0;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 5;maxval:$1f; extra:%01000000110000000000000000000000),(ptype:pt_vreg_T; offset: 16;maxval:$1f; extra:%01000000110000000000000000000000));  mask:%10111111001000001111110000000000;  value:%00001110000000000111100000000000)

  );

  ArmInstructionsAdvSIMDEXT: array of TOpcode=(
    (mnemonic:'EXT'; params:((ptype:pt_vreg_8B; offset: 0),(ptype:pt_vreg_8B; offset: 5),(ptype:pt_vreg_8B; offset: 16),(ptype:pt_imm; offset:11; maxval: $f) );  mask:%11111111111000001000010000000000;  value:%00101110000000000000000000000000),
    (mnemonic:'EXT'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_8B; offset: 5),(ptype:pt_vreg_8B; offset: 16),(ptype:pt_imm; offset:11; maxval: $f) ); mask:%11111111111000001000010000000000;  value:%01101110000000000000000000000000)
  );

  ArmInstructionsAdvSIMDScalarThreeSame: array of TOpcode=(
    (mnemonic:'SQADD'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110001000000000110000000000),
    (mnemonic:'SQADD'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000000000110000000000),
    (mnemonic:'SQADD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000000000110000000000),
    (mnemonic:'SQADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110111000000000110000000000),

    (mnemonic:'SQSUB'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110001000000010110000000000),
    (mnemonic:'SQSUB'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000000010110000000000),
    (mnemonic:'SQSUB'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000000010110000000000),
    (mnemonic:'SQSUB'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110111000000010110000000000),

    (mnemonic:'CMGT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01011110111000000011010000000000),
    (mnemonic:'CMGE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01011110111000000011110000000000),

    (mnemonic:'SSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01011110111000000100010000000000),

    (mnemonic:'SQSHL'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110001000000100110000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000000100110000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000000100110000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110111000000100110000000000),

    (mnemonic:'SRSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01011110111000000101010000000000),

    (mnemonic:'SQRSHL'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110001000000101110000000000),
    (mnemonic:'SQRSHL'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000000101110000000000),
    (mnemonic:'SQRSHL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000000101110000000000),
    (mnemonic:'SQRSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110111000000101110000000000),

    (mnemonic:'ADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01011110111000001000010000000000),
    (mnemonic:'CMTST'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01011110111000001000110000000000),

    (mnemonic:'SQDMULH'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000001011010000000000),
    (mnemonic:'SQDMULH'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000001011010000000000),

    (mnemonic:'FMULX'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110001000001101110000000000),
    (mnemonic:'FMULX'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000001101110000000000),

    (mnemonic:'FCMEQ'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110001000001110010000000000),
    (mnemonic:'FCMEQ'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000001110010000000000),

    (mnemonic:'FRECPS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110001000001111110000000000),
    (mnemonic:'FRECPS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000001111110000000000),

    (mnemonic:'FRSQRTS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000001111110000000000),
    (mnemonic:'FRSQRTS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110111000001111110000000000),

    (mnemonic:'UQADD'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110001000000000110000000000),
    (mnemonic:'UQADD'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110011000000000110000000000),
    (mnemonic:'UQADD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000000000110000000000),
    (mnemonic:'UQADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000000000110000000000),

    (mnemonic:'UQSUB'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110001000000010110000000000),
    (mnemonic:'UQSUB'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110011000000010110000000000),
    (mnemonic:'UQSUB'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000000010110000000000),
    (mnemonic:'UQSUB'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000000010110000000000),

    (mnemonic:'CMHI'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01111110111000000011010000000000),
    (mnemonic:'CMHS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01111110111000000011110000000000),
    (mnemonic:'USHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01111110111000000100010000000000),

    (mnemonic:'UQSHL'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110001000000100110000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110011000000100110000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000000100110000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000000100110000000000),

    (mnemonic:'URSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000000101010000000000),

    (mnemonic:'UQRSHL'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_breg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110001000000101110000000000),
    (mnemonic:'UQRSHL'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110011000000101110000000000),
    (mnemonic:'UQRSHL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000000101110000000000),
    (mnemonic:'UQRSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000000101110000000000),

    (mnemonic:'SUB'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01111110111000001000010000000000),

    (mnemonic:'CMEQ'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));   mask:%11111111111000001111110000000000; value:%01111110111000001000110000000000),


    (mnemonic:'SQRDMULH'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110011000001011010000000000),
    (mnemonic:'SQRDMULH'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000001011010000000000),

    (mnemonic:'FCMGE'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110001000001110010000000000),
    (mnemonic:'FCMGE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110011000001110010000000000),

    (mnemonic:'FACGE'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110001000001110110000000000),
    (mnemonic:'FACGE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110011000001110110000000000),

    (mnemonic:'FABD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000001101010000000000),
    (mnemonic:'FABD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000001101010000000000),

    (mnemonic:'FCMGT'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000001110010000000000),
    (mnemonic:'FCMGT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000001110010000000000),

    (mnemonic:'FACGT'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110101000001110110000000000),
    (mnemonic:'FACGT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_dreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01111110111000001110110000000000)


  );


  ArmInstructionsAdvSIMDScalarThreeDifferent: array of TOpcode=(
    (mnemonic:'SQDMLAL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000001001000000000000),
    (mnemonic:'SQDMLAL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000001001000000000000),

    (mnemonic:'SQDMLSL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000001011000000000000),
    (mnemonic:'SQDMLSL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000001011000000000000),

    (mnemonic:'SQDMULL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_hreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110011000001101000000000000),
    (mnemonic:'SQDMULL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_sreg; offset: 16));  mask:%11111111111000001111110000000000; value:%01011110101000001101000000000000)

  );

  ArmInstructionsAdvSIMDScalarTwoRegMisc: array of TOpcode=(
    (mnemonic:'SUQADD'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110001000000011100000000000),
    (mnemonic:'SUQADD'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110011000000011100000000000),
    (mnemonic:'SUQADD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110101000000011100000000000),
    (mnemonic:'SUQADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110111000000011100000000000),

    (mnemonic:'SQABS'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110001000000111100000000000),
    (mnemonic:'SQABS'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110011000000111100000000000),
    (mnemonic:'SQABS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110101000000111100000000000),
    (mnemonic:'SQABS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110111000000111100000000000),

    (mnemonic:'CMGT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000; value:%01011110111000001000100000000000),
    (mnemonic:'CMEQ'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000; value:%01011110111000001001100000000000),
    (mnemonic:'CMLT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000; value:%01011110111000001010100000000000),
    (mnemonic:'ABS';  params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111011111111110000000000; value:%01011110111000001011100000000000),

    (mnemonic:'SQXTN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110001000010100100000000000),
    (mnemonic:'SQXTN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110011000010100100000000000),
    (mnemonic:'SQXTN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110101000010100100000000000),

    (mnemonic:'FCVTNS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110001000011010100000000000),
    (mnemonic:'FCVTNS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110011000011010100000000000),

    (mnemonic:'FCVTMS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110001000011011100000000000),
    (mnemonic:'FCVTMS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110011000011011100000000000),

    (mnemonic:'FCVTAS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110001000011100100000000000),
    (mnemonic:'FCVTAS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01011110011000011100100000000000),

    (mnemonic:'SCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110001000011101100000000000),
    (mnemonic:'SCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110011000011101100000000000),

    (mnemonic:'FCMGT'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01011110101000001100100000000000),
    (mnemonic:'FCMGT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01011110111000001100100000000000),

    (mnemonic:'FCMEQ'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01011110101000001101100000000000),
    (mnemonic:'FCMEQ'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01011110111000001101100000000000),

    (mnemonic:'FCMLT'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01011110101000001110100000000000),
    (mnemonic:'FCMLT'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01011110111000001110100000000000),

    (mnemonic:'FCVTPS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110101000011010100000000000),
    (mnemonic:'FCVTPS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110111000011010100000000000),

    (mnemonic:'FCVTZS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110101000011011100000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110111000011011100000000000),

    (mnemonic:'FRECPE'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110101000011101100000000000),
    (mnemonic:'FRECPE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110111000011101100000000000),

    (mnemonic:'FRECPX'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110101000011111100000000000),
    (mnemonic:'FRECPX'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110111000011111100000000000),


    (mnemonic:'USQADD'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110001000000011100000000000),
    (mnemonic:'USQADD'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110011000000011100000000000),
    (mnemonic:'USQADD'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110101000000011100000000000),
    (mnemonic:'USQADD'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110111000000011100000000000),

    (mnemonic:'SQNEG'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110001000000111100000000000),
    (mnemonic:'SQNEG'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110011000000111100000000000),
    (mnemonic:'SQNEG'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110101000000111100000000000),
    (mnemonic:'SQNEG'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110111000000111100000000000),

    (mnemonic:'CMGE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000; value:%01111110111000001000100000000000),
    (mnemonic:'CMLE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000; value:%01111110111000001001100000000000),
    (mnemonic:'NEG'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));     mask:%11111111111111111111110000000000; value:%01111110111000001011100000000000),

    (mnemonic:'SQXTUN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110001000010010100000000000),
    (mnemonic:'SQXTUN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110011000010010100000000000),
    (mnemonic:'SQXTUN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110101000010010100000000000),

    (mnemonic:'UQXTN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110001000010100100000000000),
    (mnemonic:'UQXTN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110011000010100100000000000),
    (mnemonic:'UQXTN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110101000010100100000000000),


    (mnemonic:'FCVTXN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5));     mask:%11111111111111111111110000000000; value:%01111110011000010110100000000000),
    (mnemonic:'FCVTNU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110101000011010100000000000),
    (mnemonic:'FCVTNU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01011110111000011010100000000000),
    (mnemonic:'FCVTMU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110001000011011100000000000),
    (mnemonic:'FCVTMU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110011000011011100000000000),
    (mnemonic:'FCVTAU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110001000011100100000000000),
    (mnemonic:'FCVTAU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110011000011100100000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110001000011101100000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110011000011101100000000000),
    (mnemonic:'FCMGE'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01111110101000001100100000000000),
    (mnemonic:'FCMGE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01111110111000001100100000000000),
    (mnemonic:'FCMLE'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01111110101000001101100000000000),
    (mnemonic:'FCMLE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_imm_val0));  mask:%11111111111111111111110000000000;  value:%01111110111000001101100000000000),
    (mnemonic:'FCVTPU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110101000011010100000000000),
    (mnemonic:'FCVTPU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110111000011010100000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110101000011011100000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000;  value:%01111110111000011011100000000000),
    (mnemonic:'FRSQRTE'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110101000011101100000000000),
    (mnemonic:'FRSQRTE'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5));  mask:%11111111111111111111110000000000; value:%01111110111000011101100000000000)
  );

  ArmInstructionsAdvSIMDScalarPairwise: array of TOpcode=(
    (mnemonic:'ADDP'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_vreg_2D; offset:5));     mask:%11111111111111111111110000000000; value:%01011110111100011011100000000000),
    (mnemonic:'FMAXNMP'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_vreg_2S; offset:5));  mask:%11111111111111111111110000000000; value:%01111110001100011001000000000000),
    (mnemonic:'FMAXNMP'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_vreg_2D; offset:5));  mask:%11111111111111111111110000000000; value:%01111110011100011001000000000000),

    (mnemonic:'FADDP'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_vreg_2S; offset:5));    mask:%11111111111111111111110000000000; value:%01111110001100001101100000000000),
    (mnemonic:'FADDP'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_vreg_2D; offset:5));    mask:%11111111111111111111110000000000; value:%01111110011100001101100000000000),

    (mnemonic:'FMAXP'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_vreg_2S; offset:5));    mask:%11111111111111111111110000000000; value:%01111110001100001111100000000000),
    (mnemonic:'FMAXP'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_vreg_2D; offset:5));    mask:%11111111111111111111110000000000; value:%01111110011100001111100000000000),

    (mnemonic:'FMINNMP'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_vreg_2S; offset:5));  mask:%11111111111111111111110000000000; value:%01111110101100001100100000000000),
    (mnemonic:'FMINNMP'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_vreg_2D; offset:5));  mask:%11111111111111111111110000000000; value:%01111110111100001100100000000000),

    (mnemonic:'FMINP'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_vreg_2S; offset:5));  mask:%11111111111111111111110000000000; value:%01111110101100001111100000000000),
    (mnemonic:'FMINP'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_vreg_2D; offset:5));  mask:%11111111111111111111110000000000; value:%01111110111100001111100000000000)

  );

  ArmInstructionsAdvSIMDScalarCopy: array of TOpcode=(
    (mnemonic:'DUP'; params:((ptype:pt_breg; offset: 0),(ptype:pt_vreg_B_Index; offset: 5; maxval:$f; extra:17));  mask:%11111111111000011111110000000000; value:%01011110000000010000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_vreg_H_Index; offset: 5; maxval:$7; extra:18));  mask:%11111111111000111111110000000000; value:%01011110000000100000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_vreg_S_Index; offset: 5; maxval:$3; extra:19));  mask:%11111111111001111111110000000000; value:%01011110000001000000010000000000),
    (mnemonic:'DUP'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_vreg_D_Index; offset: 5; maxval:$1; extra:20));  mask:%11111111111011111111110000000000; value:%01011110000010000000010000000000)

  );

  ArmInstructionsAdvSIMDScalarXIndexedElement: array of TOpcode=(
    (mnemonic:'SQDMLAL'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_hreg; offset: 5), (ptype: pt_vreg_H_HLMIndex; offset:16; maxval:$f)); mask:%11111111110000001111010000000000; value:%01011111010000000011000000000000),
    (mnemonic:'SQDMLAL'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f)); mask:%11111111110000001111010000000000; value:%01011111100000000011000000000000),

    (mnemonic:'SQDMLSL'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_hreg; offset: 5), (ptype: pt_vreg_H_HLMIndex; offset:16; maxval:$f)); mask:%11111111110000001111010000000000; value:%01011111010000000111000000000000),
    (mnemonic:'SQDMLSL'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f)); mask:%11111111110000001111010000000000; value:%01011111100000000111000000000000),

    (mnemonic:'SQDMULL'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_hreg; offset: 5), (ptype: pt_vreg_H_HLMIndex; offset:16; maxval:$f)); mask:%11111111110000001111010000000000; value:%01011111010000001011000000000000),
    (mnemonic:'SQDMULL'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f)); mask:%11111111110000001111010000000000; value:%01011111100000001011000000000000),

    (mnemonic:'SQDMULH'; params:((ptype:pt_hreg; offset: 0), (ptype:pt_hreg; offset: 5), (ptype: pt_vreg_H_HLMIndex; offset:16; maxval:$f)); mask:%11111111110000001111010000000000; value:%01011111010000001100000000000000),
    (mnemonic:'SQDMULH'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f)); mask:%11111111110000001111010000000000; value:%01011111100000001100000000000000),

    (mnemonic:'SQRDMULH';params:((ptype:pt_hreg; offset: 0), (ptype:pt_hreg; offset: 5), (ptype: pt_vreg_H_HLMIndex; offset:16; maxval:$f)); mask:%11111111110000001111010000000000; value:%01011111010000001101000000000000),
    (mnemonic:'SQRDMULH';params:((ptype:pt_sreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f)); mask:%11111111110000001111010000000000; value:%01011111100000001101000000000000),

    (mnemonic:'FMLA'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f));mask:%11111111110000001111010000000000; value:%01011111100000000001000000000000),
    (mnemonic:'FMLA'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_dreg; offset: 5), (ptype: pt_vreg_D_HIndex; offset:16; maxval:$1f)); mask:%11111111111000001111010000000000; value:%01011111110000000001000000000000),

    (mnemonic:'FMLS'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f));mask:%11111111110000001111010000000000; value:%01011111100000000101000000000000),
    (mnemonic:'FMLS'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_dreg; offset: 5), (ptype: pt_vreg_D_HIndex; offset:16; maxval:$1f)); mask:%11111111111000001111010000000000; value:%01011111110000000101000000000000),

    (mnemonic:'FMUL'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f));mask:%11111111110000001111010000000000; value:%01011111100000001001000000000000),
    (mnemonic:'FMUL'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_dreg; offset: 5), (ptype: pt_vreg_D_HIndex; offset:16; maxval:$1f)); mask:%11111111111000001111010000000000; value:%01011111110000001001000000000000),

    (mnemonic:'FMULX'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype: pt_vreg_S_HLIndex; offset:16; maxval:$1f));mask:%11111111110000001111010000000000; value:%01111111100000001001000000000000),
    (mnemonic:'FMULX'; params:((ptype:pt_dreg; offset: 0), (ptype:pt_dreg; offset: 5), (ptype: pt_vreg_D_HIndex; offset:16; maxval:$1f)); mask:%11111111111000001111010000000000; value:%01111111110000001001000000000000)

  );

  ArmInstructionsAdvSIMDScalarShiftByImmediate: array of TOpcode=(
    (mnemonic:'SSHR'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000; value:%01011111010000000000010000000000),
    (mnemonic:'SSRA'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000; value:%01011111010000000001010000000000),
    (mnemonic:'SRSHR'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01011111010000000010010000000000),
    (mnemonic:'SRSRA'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01011111010000000011010000000000),
    (mnemonic:'SHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));   mask:%11111111110000001111110000000000; value:%01011111010000000101010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8));  mask:%11111111111110001111110000000000; value:%01011111000010000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000; value:%01011111000100000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000; value:%01011111001000000111010000000000),
    (mnemonic:'SQSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:64)); mask:%11111111110000001111110000000000; value:%01011111010000000111010000000000),

    (mnemonic:'SQSHRN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%01011111000010001001010000000000),
    (mnemonic:'SQSHRN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%01011111000100001001010000000000),
    (mnemonic:'SQSHRN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01011111001000001001010000000000),

    (mnemonic:'SQRSHRN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16)); mask:%11111111111110001111110000000000; value:%01001111000010001001110000000000),
    (mnemonic:'SQRSHRN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32)); mask:%11111111111100001111110000000000; value:%01011111000100001001110000000000),
    (mnemonic:'SQRSHRN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64)); mask:%11111111111000001111110000000000; value:%01011111001000001001110000000000),

    (mnemonic:'SCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));   mask:%11111111111000001111110000000000; value:%01011111001000001110010000000000),
    (mnemonic:'SCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000; value:%01011111010000001110010000000000),

    (mnemonic:'FCVTZS'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));   mask:%11111111111000001111110000000000; value:%01011111001000001111110000000000),
    (mnemonic:'FCVTZS'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000; value:%01011111010000001111110000000000),


    (mnemonic:'USHR'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000; value:%01111111010000000000010000000000),
    (mnemonic:'USRA'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000; value:%01111111010000000001010000000000),
    (mnemonic:'URSHR'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01111111010000000010010000000000),
    (mnemonic:'URSRA'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128)); mask:%11111111110000001111110000000000; value:%01111111010000000011010000000000),
    (mnemonic:'SRI'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));   mask:%11111111110000001111110000000000; value:%01111111010000000100010000000000),
    (mnemonic:'SLI'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));   mask:%11111111110000001111110000000000; value:%01111111010000000101010000000000),


    (mnemonic:'SQSHLU'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8));  mask:%11111111111110001111110000000000; value:%01111111000010000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000; value:%01111111000100000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000; value:%01111111001000000110010000000000),
    (mnemonic:'SQSHLU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:64)); mask:%11111111110000001111110000000000; value:%01111111010000000110010000000000),

    (mnemonic:'UQSHL'; params:((ptype:pt_breg; offset: 0),(ptype:pt_breg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:8));  mask:%11111111111110001111110000000000; value:%01111111000010000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:16)); mask:%11111111111100001111110000000000; value:%01111111000100000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:32)); mask:%11111111111000001111110000000000; value:%01111111001000000111010000000000),
    (mnemonic:'UQSHL'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_immminx; offset: 16; maxval: $7f; extra:64)); mask:%11111111110000001111110000000000; value:%01111111010000000111010000000000),

    (mnemonic:'SQSHRUN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000;  value:%01111111000010001000010000000000),
    (mnemonic:'SQSHRUN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000;  value:%01111111000100001000010000000000),
    (mnemonic:'SQSHRUN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000;  value:%01111111001000001000010000000000),

    (mnemonic:'SQRSHRUN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%01111111000010001000110000000000),
    (mnemonic:'SQRSHRUN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%01111111000100001000110000000000),
    (mnemonic:'SQRSHRUN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01111111001000001000110000000000),


    (mnemonic:'UQSHRN'; params:((ptype:pt_breg; offset: 0),(ptype:pt_hreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:16));  mask:%11111111111110001111110000000000; value:%01111111000010001001010000000000),
    (mnemonic:'UQSHRN'; params:((ptype:pt_hreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:32));  mask:%11111111111100001111110000000000; value:%01111111000100001001010000000000),
    (mnemonic:'UQSHRN'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));  mask:%11111111111000001111110000000000; value:%01111111001000001001010000000000),


    (mnemonic:'UCVTF'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));   mask:%11111111111000001111110000000000; value:%01111111001000001110010000000000),
    (mnemonic:'UCVTF'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000; value:%01111111010000001110010000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_sreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:64));   mask:%11111111111000001111110000000000;value:%01111111001000001111110000000000),
    (mnemonic:'FCVTZU'; params:((ptype:pt_dreg; offset: 0),(ptype:pt_dreg; offset: 5),(ptype:pt_xminimm; offset: 16; maxval: $7f; extra:128));  mask:%11111111110000001111110000000000;value:%01111111010000001111110000000000)


  );

  ArmInstructionsCryptoAES: array of TOpcode=(
    (mnemonic:'AESE'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5));   mask:%11111111111111111111110000000000; value:%01001110001010000100100000000000),
    (mnemonic:'AESD'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5));   mask:%11111111111111111111110000000000; value:%01001110001010000101100000000000),
    (mnemonic:'AESMC'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5));  mask:%11111111111111111111110000000000; value:%01001110001010000110100000000000),
    (mnemonic:'AESIMC'; params:((ptype:pt_vreg_16B; offset: 0),(ptype:pt_vreg_16B; offset: 5)); mask:%11111111111111111111110000000000; value:%01001110001010000111100000000000)
  );

  ArmInstructionsCryptoThreeRegSHA: array of TOpcode=(
    (mnemonic:'SHA1C'; params:((ptype:pt_qreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype:pt_vreg_4S; offset: 16)); mask:%11111111111000001111110000000000; value:%01011110000000000000000000000000),
    (mnemonic:'SHA1P'; params:((ptype:pt_qreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype:pt_vreg_4S; offset: 16)); mask:%11111111111000001111110000000000; value:%01011110000000000001000000000000),
    (mnemonic:'SHA1M'; params:((ptype:pt_qreg; offset: 0), (ptype:pt_sreg; offset: 5), (ptype:pt_vreg_4S; offset: 16)); mask:%11111111111000001111110000000000; value:%01011110000000000010000000000000),
    (mnemonic:'SHA1SU0'; params:((ptype:pt_qreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_vreg_4S; offset: 16)); mask:%11111111111000001111110000000000; value:%01011110000000000011000000000000),
    (mnemonic:'SHA256H'; params:((ptype:pt_qreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_vreg_4S; offset: 16)); mask:%11111111111000001111110000000000; value:%01011110000000000100000000000000),
    (mnemonic:'SHA256H2';params:((ptype:pt_qreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_vreg_4S; offset: 16)); mask:%11111111111000001111110000000000; value:%01011110000000000101000000000000),
    (mnemonic:'SHA256SU1';params:((ptype:pt_qreg; offset: 0),(ptype:pt_sreg; offset: 5),(ptype:pt_vreg_4S; offset: 16));mask:%11111111111000001111110000000000; value:%01011110000000000110000000000000)
  );


  ArmInstructionsCryptoTwoRegSHA: array of TOpcode=(
    (mnemonic:'SHA1H'; params:((ptype:pt_sreg; offset: 0), (ptype:pt_sreg; offset: 5)); mask:%11111111111111111111110000000000; value:%01011110001010000000100000000000),
    (mnemonic:'SHA1SU1';params:((ptype:pt_sreg;offset: 0), (ptype:pt_sreg; offset: 5)); mask:%11111111111111111111110000000000; value:%01011110001010000001100000000000),
    (mnemonic:'SHA256SU0';params:((ptype:pt_sreg;offset:0),(ptype:pt_sreg; offset: 5)); mask:%11111111111111111111110000000000; value:%01011110001010000010100000000000)
  );


  //--------------------------- instruction groups----------------------------//
  ArmGroupDataProcessing: array of TInstructionGroup=(
    (mask:%00011111000000000000000000000000; value: %00010000000000000000000000000000; list: @ArmInstructionsPCRelAddressing; listType: igpInstructions),
    (mask:%00011111000000000000000000000000; value: %00010001000000000000000000000000; list: @ArmInstructionsAddSubtractImm; listType: igpInstructions),
    (mask:%00011111100000000000000000000000; value: %00010010000000000000000000000000; list: @ArmInstructionsLogicalImm; listType: igpInstructions),
    (mask:%00011111100000000000000000000000; value: %00010010100000000000000000000000; list: @ArmInstructionsMoveWideImm; listType: igpInstructions),
    (mask:%00011111100000000000000000000000; value: %00010011000000000000000000000000; list: @ArmInstructionsBitField; listType: igpInstructions),
    (mask:%00011111100000000000000000000000; value: %00010011100000000000000000000000; list: @ArmInstructionsExtract; listType: igpInstructions)
  );


  ArmGroupBranchExceptionGenerationAndSystemInstructions: array of TInstructionGroup=(
   (mask:%01111100000000000000000000000000; value: %00010100000000000000000000000000; list: @ArmInstructionsUnconditionalBranchImm; listType: igpInstructions),
   (mask:%01111110000000000000000000000000; value: %00110100000000000000000000000000; list: @ArmInstructionsCompareAndBranch; listType: igpInstructions),
   (mask:%01111110000000000000000000000000; value: %00110110000000000000000000000000; list: @ArmInstructionsTestAndBranchImm; listType: igpInstructions),
   (mask:%11111110000000000000000000000000; value: %01010100000000000000000000000000; list: @ArmInstructionsConditionalBranchImm; listType: igpInstructions),
   (mask:%11111111000000000000000000000000; value: %11010100000000000000000000000000; list: @ArmInstructionsExceptionGen; listType: igpInstructions),
   (mask:%11111111110000000000000000000000; value: %11010101000000000000000000000000; list: @ArmInstructionsSystem; listType: igpInstructions),
   (mask:%11111110000000000000000000000000; value: %11010110000000000000000000000000; list: @ArmInstructionsUnconditionalBranchReg; listType: igpInstructions)
  );




  ArmGroupLoadsAndStores: array of TInstructionGroup=(
   (mask:%00111111000000000000000000000000; value: %00001000000000000000000000000000; list: @ArmInstructionsLoadStoreExlusive; listType: igpInstructions),
   (mask:%00111011000000000000000000000000; value: %00011000000000000000000000000000; list: @ArmInstructionsLoadRegisterLiteral; listType: igpInstructions),
   (mask:%00111011100000000000000000000000; value: %00101000000000000000000000000000; list: @ArmInstructionsLoadStoreNoAllocatePairOffset; listType: igpInstructions),
   (mask:%00111011100000000000000000000000; value: %00101000100000000000000000000000; list: @ArmInstructionsLoadStoreRegisterPairPostIndexed; listType: igpInstructions),
   (mask:%00111011100000000000000000000000; value: %00101001000000000000000000000000; list: @ArmInstructionsLoadStoreRegisterPairOffset; listType: igpInstructions),
   (mask:%00111011100000000000000000000000; value: %00101001100000000000000000000000; list: @ArmInstructionsLoadStoreRegisterPairPreIndexed; listType: igpInstructions),
   (mask:%00111011001000000000110000000000; value: %00111000000000000000000000000000; list: @ArmInstructionsLoadStoreRegisterUnscaledImmediate; listType: igpInstructions),
   (mask:%00111011001000000000110000000000; value: %00111000000000000000010000000000; list: @ArmInstructionsLoadStoreRegisterImmediatePostIndexed; listType: igpInstructions),
   (mask:%00111011001000000000110000000000; value: %00111000000000000000100000000000; list: @ArmInstructionsLoadStoreRegisterUnprivileged; listType: igpInstructions),
   (mask:%00111011001000000000110000000000; value: %00111000000000000000110000000000; list: @ArmInstructionsLoadStoreRegisterImmediatePreIndexed; listType: igpInstructions),
   (mask:%00111011001000000000110000000000; value: %00111000001000000000100000000000; list: @ArmInstructionsLoadStoreRegisterRegisterOffset; listType: igpInstructions),
   (mask:%00111011000000000000000000000000; value: %00111001000000000000000000000000; list: @ArmInstructionsLoadStoreRegisterUnsignedImmediate; listType: igpInstructions),
   (mask:%10111111101111110000000000000000; value: %00001100000000000000000000000000; list: @ArmInstructionsAdvSIMDLoadStoreMultipleStructures; listType: igpInstructions),
   (mask:%10111111101000000000000000000000; value: %00001100100000000000000000000000; list: @ArmInstructionsAdvSIMDLoadStoreMultipleStructuresPostIndexed; listType: igpInstructions),
   (mask:%10111111100111110000000000000000; value: %00001101000000000000000000000000; list: @ArmInstructionsAdvSIMDLoadStoreSingleStructure; listType: igpInstructions),
   (mask:%10111111100000000000000000000000; value: %00001101100000000000000000000000; list: @ArmInstructionsAdvSIMDLoadStoreSingleStructurePostIndexed; listType: igpInstructions)

  );

  ArmGroupDataProcessingRegister: array of TInstructionGroup=(
    (mask:%00011111000000000000000000000000; value: %00001010000000000000000000000000; list: @ArmInstructionsLogicalShiftedRegister; listType: igpInstructions),
    (mask:%00011111001000000000000000000000; value: %00001011000000000000000000000000; list: @ArmInstructionsAddSubtractShiftedRegister; listType: igpInstructions),
    (mask:%00011111001000000000000000000000; value: %00001011001000000000000000000000; list: @ArmInstructionsAddSubtractExtendedRegister; listType: igpInstructions),
    (mask:%00011111111000000000000000000000; value: %00011010000000000000000000000000; list: @ArmInstructionsAddSubtractWithCarry; listType: igpInstructions),
    (mask:%00011111111000000000000000000010; value: %00011010010000000000000000000000; list: @ArmInstructionsConditionalCompareRegister; listType: igpInstructions),
    (mask:%00011111111000000000000000000010; value: %00011010010000000000000000000010; list: @ArmInstructionsConditionalCompareImmediate; listType: igpInstructions),
    (mask:%00011111111000000000000000000000; value: %00011010100000000000000000000000; list: @ArmInstructionsCondionalSelect; listType: igpInstructions),
    (mask:%00011111000000000000000000000000; value: %00011011000000000000000000000000; list: @ArmInstructionsDataProcessing3Source; listType: igpInstructions),
    (mask:%01011111111000000000000000000000; value: %00011010110000000000000000000000; list: @ArmInstructionsDataProcessing2Source; listType: igpInstructions),
    (mask:%01011111111000000000000000000000; value: %01011010110000000000000000000000; list: @ArmInstructionsDataProcessing1Source; listType: igpInstructions)
  );

  ArmGroupSIMDAndFP: array of TInstructionGroup=(
    (mask:%01011111001000000000000000000000; value: %00011110000000000000000000000000; list: @ArmInstructionsFloatingPoint_FixedPointConversions; listType: igpInstructions),
    (mask:%01011111001000000000110000000000; value: %00011110001000000000010000000000; list: @ArmInstructionsFloatingPointConditionalCompare; listType: igpInstructions),
    (mask:%01011111001000000000110000000000; value: %00011110001000000000100000000000; list: @ArmInstructionsFloatingPointDataProcessing2Source; listType: igpInstructions),
    (mask:%01011111001000000000110000000000; value: %00011110001000000000110000000000; list: @ArmInstructionsFloatingPointConditionalSelect; listType: igpInstructions),
    (mask:%01011111001000000001110000000000; value: %00011110001000000001000000000000; list: @ArmInstructionsFloatingPointImmediate; listType: igpInstructions),
    (mask:%01011111001000000011110000000000; value: %00011110001000000010000000000000; list: @ArmInstructionsFloatingPointCompare; listType: igpInstructions),
    (mask:%01011111001000000111110000000000; value: %00011110001000000100000000000000; list: @ArmInstructionsFloatingPointDataProcessing1Source; listType: igpInstructions),
    (mask:%01011111001000001111110000000000; value: %00011110001000000000000000000000; list: @ArmInstructionsFloatingPoint_IntegerConversions; listType: igpInstructions),
    (mask:%01011111000000000000000000000000; value: %00011111000000000000000000000000; list: @ArmInstructionsFloatingPointDataProcessing3Source; listType: igpInstructions),
    (mask:%10011111001000000000010000000000; value: %00001110001000000000010000000000; list: @ArmInstructionsAdvSIMDThreeSame; listType: igpInstructions),
    (mask:%10011111001000000000110000000000; value: %00001110001000000000000000000000; list: @ArmInstructionsAdvSIMDThreeDifferent; listType: igpInstructions),
    (mask:%10011111001111100000110000000000; value: %00001110001000000000100000000000; list: @ArmInstructionsAdvSIMDTwoRegMisc; listType: igpInstructions),
    (mask:%10011111001111100000110000000000; value: %00001110001100000000100000000000; list: @ArmInstructionsAdvSIMDAcrossLanes; listType: igpInstructions),
    (mask:%10011111111000001000010000000000; value: %00001110000000000000010000000000; list: @ArmInstructionsAdvSIMDCopy; listType: igpInstructions),
    (mask:%10011111000000000000010000000000; value: %00001111000000000000000000000000; list: @ArmInstructionsAdvSIMDVectorXIndexedElement; listType: igpInstructions),
    (mask:%10011111111110000000010000000000; value: %00001111000000000000010000000000; list: @ArmInstructionsAdvSIMDModifiedImmediate; listType: igpInstructions),
    (mask:%10011111100000000000010000000000; value: %00001111000000000000010000000000; list: @ArmInstructionsAdvSIMDShiftByImmediate; listType: igpInstructions),
    (mask:%10111111001000001000110000000000; value: %00001110000000000000000000000000; list: @ArmInstructionsAdvSIMDTBLTBX; listType: igpInstructions),
    (mask:%10111111001000001000110000000000; value: %00001110000000000000100000000000; list: @ArmInstructionsAdvSIMDZIPUNZTRN; listType: igpInstructions),
    (mask:%10111111001000001000010000000000; value: %00101110000000000000000000000000; list: @ArmInstructionsAdvSIMDEXT; listType: igpInstructions),
    (mask:%11011111001000000000010000000000; value: %01011110001000000000010000000000; list: @ArmInstructionsAdvSIMDScalarThreeSame; listType: igpInstructions),
    (mask:%11011111001000000000110000000000; value: %01011110001000000000000000000000; list: @ArmInstructionsAdvSIMDScalarThreeDifferent; listType: igpInstructions),
    (mask:%11011111001111100000110000000000; value: %01011110001000000000100000000000; list: @ArmInstructionsAdvSIMDScalarTwoRegMisc; listType: igpInstructions),
    (mask:%11011111001111100000110000000000; value: %01011110001100000000100000000000; list: @ArmInstructionsAdvSIMDScalarPairwise; listType: igpInstructions),
    (mask:%11011111111000001000010000000000; value: %01011110000000000000010000000000; list: @ArmInstructionsAdvSIMDScalarCopy; listType: igpInstructions),
    (mask:%11011111000000000000000000000000; value: %01011111000000000000000000000000; list: @ArmInstructionsAdvSIMDScalarXIndexedElement; listType: igpInstructions),
    (mask:%11011111100000000000010000000000; value: %01011111000000000000010000000000; list: @ArmInstructionsAdvSIMDScalarShiftByImmediate; listType: igpInstructions),
    (mask:%11111111001111100000110000000000; value: %01001110001010000000100000000000; list: @ArmInstructionsCryptoAES; listType: igpInstructions),
    (mask:%11111111001000001000110000000000; value: %01011110000000000000000000000000; list: @ArmInstructionsCryptoThreeRegSHA; listType: igpInstructions),
    (mask:%11111111001111100000110000000000; value: %01011110001010000000100000000000; list: @ArmInstructionsCryptoTwoRegSHA; listType: igpInstructions)
  );



  ArmGroupBase: array of TInstructionGroup=(
    (mask:%00011000000000000000000000000000; value: %00000000000000000000000000000000; list: @ArmInstructionsUNALLOCATED; listType: igpInstructions),
    (mask:%00011100000000000000000000000000; value: %00010000000000000000000000000000; list: @ArmGroupDataProcessing; listType: igpGroup),
    (mask:%00011100000000000000000000000000; value: %00010100000000000000000000000000; list: @ArmGroupBranchExceptionGenerationAndSystemInstructions; listType: igpGroup),
    (mask:%00001010000000000000000000000000; value: %00001000000000000000000000000000; list: @ArmGroupLoadsAndStores; listType: igpGroup),
    (mask:%00001110000000000000000000000000; value: %00001010000000000000000000000000; list: @ArmGroupDataProcessingRegister; listType: igpGroup),
    (mask:%00001110000000000000000000000000; value: %00001110000000000000000000000000; list: @ArmGroupSIMDAndFP; listType: igpGroup)
  );

var
  ArmInstructionsAssemblerList: TStringHashList;




function SignExtend(value: qword; mostSignificantBit: integer): qword; inline;
{
Signextends a given offset. mostSignificant bit defines what bit determines if it should be sign extended or not
}
begin
  if (value shr mostSignificantBit)=1 then //needs to be sign extended
      value:=value or ((qword($ffffffffffffffff) shl mostSignificantBit));

  result:=value;
end;

function TArm64Disassembler.GetIMM2Value(mask: dword): dword;
//scan the bitmask for 1's and convert them a value
var
  i: integer;
  startbit: integer;
  bitcount: integer;

begin
  //scan for the first bit
  result:=0;
  startbit:=-1;
  for i:=0 to 31 do
  begin
    if (mask and (1 shl i)) <> 0 then
    begin
      //found the start
      startbit:=i;
      break;
    end;
  end;

  if startbit=-1 then exit;

  bitcount:=0;
  for i:=startbit to 31 do
  begin
    if (mask and (1 shl i))<>0 then
    begin
      if (opcode and (1 shl i))<>0 then
        result:=result or (1 shl bitcount);

      inc(bitcount);
    end;
  end;
end;

function TArm64Disassembler.GetIMM2_8Value(mask: dword): qword;
//scan the bitmask for 1's and convert them a value (there are 8 bits in this mask)
var
  v: byte;
  r: qword;
  i,j: integer;
begin
  result:=0;
  v:=GetIMM2Value(mask);
  for i:=0 to 7 do
  begin
    for j:=i*8 to (i+1)*8-1 do
      result:=result or (((v shr i) and 1) shl j);
  end;


end;

function highestbit(v: dword): integer;
var i: integer;
begin
  case v of
     $1ff: exit(9);
     $3fff: exit(14);
     $7fff: exit(15);
     $ffff: exit(16);
    $1ffff: exit(17);
    $3ffff: exit(18);
    $7ffff: exit(19);
    $7ffffff: exit(26);
    else
    begin
      result:=0;
      for i:=31 downto 0 do
        if (v and (1 shl i))<>0 then exit(i);
    end;
  end;
end;

function ones(len: integer): qword;
begin
  result:=qword(qword(1) shl len)-1;
end;

function zeroextend(v: qword; bitlen: integer): qword;
begin
  result:=v and ones(bitlen);
end;

function ror(v: qword; esize: integer; r: integer): qword;
var a,b: qword;
begin
  a:=v shl (esize-r) and ones(esize);
  b:=v shr r and ones(esize);

  result:=(a or b) and ones(esize);

end;

function replicate(v: qword; sourceSize: integer; destinationSize: integer): qword;
var
  repval: qword;
  times: integer;
  i: integer;
  r: qword;
begin
  if sourcesize=0 then exit;

  repval:=v and zeroextend(v, sourcesize);

  times:=destinationsize div sourcesize;
  result:=0;
  for i:=1 to times do
    result:=(result shl sourcesize) or repval;

  result:=result or repval;
end;

function armbitmask(v: qword; datasize: integer): qword;
var
  d: bitpacked record
    imms: 0..$3f;
    immr: 0..$3f;
    immN: 0..1;
  end absolute v;

  len,len2: integer;
  levels,level2: integer;

  s: integer;
  r: integer;
  diff: integer;
  esize: integer;
  welem: qword;
  telem: qword;

  _d: integer;

  scratch: bitpacked record
    v: 0..$3f;
    tmask_and, wmask_and: 0..$3f;
    tmask_or, wmask_or: 0..$3f;
    levels: 0..$3f;
  end;

  tmask: qword;
  wmask: qword;
begin
  result:=0;
  scratch.v:=d.imms;
  scratch.v:=not scratch.v;


  len:=highestbit((d.immn shl 6) or (scratch.v));
  if len<1 then exit(0);

  scratch.v:=ones(len);
  levels:=scratch.v;

  s:=d.imms and levels;
  r:=d.immr and levels;
  diff:=s-r;

  esize:=1 shl len;

  _d:=diff and (ones(len-1));

  welem:=zeroextend(ones(s+1), esize);
  telem:=zeroextend(ones(_d+1), esize);

  wmask:=replicate(ror(welem, esize, r), esize, datasize);
  tmask:=replicate(telem, esize, datasize);

  exit(wmask);
end;

function bhsd(encoding2: integer): string;
begin
  case encoding2 and 3 of
    %00: exit('B');
    %01: exit('H');
    %10: exit('S');
    %11: exit('D');
  end;
end;

function bhsd2(encoding2: integer): string;
begin
  case encoding2 and 3 of
    %01: exit('B');
    %10: exit('H');
    %11: exit('S');
  end;
end;

function getVectorSizeString(encoding3: integer): string;
begin
  case encoding3 of
    %000: result:='8B';
    %001: result:='4H';
    %010: result:='2S';
    %011: result:='1D';
    %100: result:='16B';
    %101: result:='8H';
    %110: result:='4S';
    %111: result:='2D';
    else result:='invalid';
  end
end;

function getVectorSizeString2(encoding3: integer): string;
begin
  case encoding3 of
    %000: result:='4H';
    %001: result:='2S';
    %010: result:='1D';
    %100: result:='8H';
    %101: result:='4S';
    %110: result:='2D';
    else result:='invalid';
  end
end;

function getVectorRegisterString(regnr: integer; encoding3: integer): string;
begin
  result:='V'+inttostr(regnr)+'.'+getVectorSizeString(encoding3);
end;

function getVectorRegisterListString(startreg: integer; encoding3: integer; len: integer):string;
var s: string;
begin
  s:=getVectorSizeString(encoding3);
  result:='{V'+inttostr(startreg)+'.'+s;
  if len>1 then
    result:=result+'-V'+inttostr((startreg+len-1) mod 32)+'.'+s;

  result:=result+'}';
end;

function fp8tofloat(v: byte): single;
var
  n: integer;
  e: integer;
  f: integer;
  sign: integer;
  exp: integer;
  frac: integer;

  r: single;
  fr: bitpacked record
    sign: 1..1;
    exp: 0..255;
    frac: 0..$3FFFFF;
  end absolute r;

begin
  r:=0;
  n:=32;
  e:=8;
  f:=n-e-1;

  fr.sign:=(v shr 7) and 1;
  fr.exp:=(not((v shr 6) and 1) shr 7) or (replicate((v shr 6) and 1, 1,e-3) shl 2) or ((v shr 4) and 3);
  fr.frac:=(v and $f) shl 18;

  result:=r;

end;

function TArm64Disassembler.ParseParameters(plist: TAParametersList): boolean;
var
  i: integer;
  v,v2,v3: dword;
  qv: qword;

  p,s: string;

  insideIndex: boolean;
begin
  result:=true;
  insideIndex:=false;

  for i:=0 to length(plist)-1 do
  begin

    p:='';




    case plist[i].ptype of
      pt_creg:
      begin
        v:=(opcode shr plist[i].offset) and 15;
        p:='C'+inttostr(v);
      end;

      pt_xreg,pt_wreg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        if plist[i].ptype=pt_xreg then
          p:=ArmRegistersNoName[v]
        else
          p:=ArmRegistersNoName32[v];

      end;

      pt_wreg2x, pt_xreg2x:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        v2:=(opcode shr plist[i].extra) and 31;

        if v<>v2 then exit(false); //invalid instruction for this opcode
      end;

      pt_breg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='B'+inttostr(v);
      end;

      pt_hreg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='H'+inttostr(v);
      end;

      pt_sreg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='S'+inttostr(v);
      end;

      pt_dreg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='D'+inttostr(v);
      end;

      pt_qreg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='Q'+inttostr(v);
      end;

      pt_sdreg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        case (opcode shr 22) and 3 of
          0,3: exit(false);
          1: p:='S'+inttostr(v);
          2: p:='D'+inttostr(v);
        end;
      end;

      pt_hsreg:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        case (opcode shr 22) and 3 of
          0,3: exit(false);
          1: p:='H'+inttostr(v);
          2: p:='S'+inttostr(v);
        end;
      end;


      pt_vreg_8B:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='V'+inttostr(v)+'.8B';
      end;

      pt_vreg_16B:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='V'+inttostr(v)+'.16B';
      end;

      pt_vreg_4H:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='V'+inttostr(v)+'.4H';
      end;

      pt_vreg_8H:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='V'+inttostr(v)+'.8H';
      end;

      pt_vreg_2S:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='V'+inttostr(v)+'.2S';
      end;

      pt_vreg_4S:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='V'+inttostr(v)+'.4S';
      end;

      pt_vreg_2D:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        p:='V'+inttostr(v)+'.2D';
      end;


      pt_vreg_B_Index:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        v2:=(opcode shr plist[i].extra) and (plist[i].maxval);
        p:='V'+inttostr(v)+'.B['+inttohex(v2,1)+']';
      end;

      pt_vreg_SD_HLIndex: //HL bits 11:21  size: 22
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        p:='V'+inttostr(v)+'.';

        v:=(opcode shr 22) and 1;
        case v of
          0:
          begin
            v2:=((opcode shr 21) and 1) or ((opcode shr 10) and 4);
            p:='.S['+inttohex(v2,1)+']';
          end;

          1:
          begin
            v2:=(opcode shr 11) and 1;
            p:='.D['+inttohex(v2,1)+']';
          end;
        end;
      end;

      pt_vreg_HS_HLMIndex: //HLM bits 11:21:20  size: 23:22
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        p:='V'+inttostr(v)+'.';

        v:=(opcode shr 22) and 3;
        case v of
          1:
          begin
            v2:=((opcode shr 20) and 3) or ((opcode shr 9) and 4);
            p:='.H['+inttohex(v2,1)+']';
          end;

          2:
          begin
            v2:=((opcode shr 21) and 1) or ((opcode shr 10) and 2);
            p:='.S['+inttohex(v2,1)+']';
          end;
        end;
      end;


      pt_vreg_H_HLMIndex: //HLM = bits 11:21:20
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        v2:=((opcode shr 20) and 3) or ((opcode shr 9) and 4) ;
        p:='V'+inttostr(v)+'.H['+inttohex(v2,1)+']';
      end;

      pt_vreg_S_HLIndex: //bits: 11:21
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        v2:=((opcode shr 21) and 1) or ((opcode shr 10) and 2) ;
        p:='V'+inttostr(v)+'.S['+inttohex(v2,1)+']';
      end;

      pt_vreg_D_HIndex: //bit: 11
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        v2:=(opcode shr 11) and 1;
        p:='V'+inttostr(v)+'.D['+inttohex(v2,1)+']';
      end;

      pt_vreg_H_Index:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        v2:=(opcode shr plist[i].extra) and (plist[i].maxval);
        p:='V'+inttostr(v)+'.H['+inttohex(v2,1)+']';
      end;

      pt_vreg_S_Index:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        v2:=(opcode shr plist[i].extra) and (plist[i].maxval);
        p:='V'+inttostr(v)+'.S['+inttohex(v2,1)+']';
      end;

      pt_vreg_D_Index:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        v2:=(opcode shr plist[i].extra) and (plist[i].maxval);
        p:='V'+inttostr(v)+'.D['+inttohex(v2,1)+']';
      end;

      pt_vreg_D_Index1:
      begin
        v:=(opcode shr plist[i].offset) and 31;
        v2:=(opcode shr plist[i].extra) and (plist[i].maxval);
        p:='V'+inttostr(v)+'.D[1]';
      end;

      pt_label:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        v:=v shl 2;
        qv:=address+SignExtend(v,highestbit(plist[i].maxval)+2);



        p:=inttohex(qv,8);
      end;

      pt_addrlabel:
      begin
        v:=((opcode shr 5) and $7FFFF) or ((opcode shr 29) and 3);
        v:=signextend(v,20);
        if plist[i].extra=1 then
          v:=v shl 12;
        qv:=address+v;

        p:=inttohex(qv,8);
      end;

      pt_pstatefield_SP: p:='SPSEL';
      pt_pstatefield_DAIFSet: p:='DAIFSET';
      pt_pstatefield_DAIFClr: p:='DAIFCLR';

      pt_barrierOption:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        if plist[i].optional and (plist[i].defvalue=v) then continue;
        case v of
          1: p:='OSHLD';
          2: p:='OSHST';
          3: p:='OSH';
          5: p:='NSHLD';
          6: p:='NSHST';
          7: p:='NSH';
          9: p:='ISHLD';
          10: p:='ISHST';
          11: p:='ISH';
          13: p:='LD';
          14: p:='ST';
          15: p:='SY';
          else
            p:='#'+inttohex(v,1);
        end;
      end;

      pt_imm_1shlval: //take the number 1 and shift it left x times
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        p:='#'+inttohex(1 shl v,1);
      end;

      pt_imm_val0_0: p:='#0.0';
      pt_imm_val0: p:='#0';
      pt_imm_val1: p:='#1';
      pt_imm_val2: p:='#2';
      pt_imm_val4: p:='#4';
      pt_imm_val8: p:='#8';

      pt_imm_mul4:
      begin
        v:=((opcode shr plist[i].offset) and plist[i].maxval)*4;
        p:='#'+inttohex(v,1);
      end;

      pt_imm_mul8:
      begin
        v:=((opcode shr plist[i].offset) and plist[i].maxval)*8;
        p:='#'+inttohex(v,1);
      end;

      pt_imm_mul16:
      begin
        v:=((opcode shr plist[i].offset) and plist[i].maxval)*16;
        p:='#'+inttohex(v,1);
      end;


      pt_imm32or64:
      begin
        v:=(opcode shr plist[i].offset) and 1;
        if v=0 then
          v:=32
        else
          v:=64;

        p:=p+'#'+inttohex(v,1);
      end;

      pt_imm2:
      begin
        v:=GetIMM2Value(plist[i].offset);
        p:='#'+inttohex(v,2);
      end;

      pt_imm2_8:
      begin
        v:=GetIMM2_8Value(plist[i].offset);
        p:='#'+inttohex(v,2);
      end;

      pt_immminx:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        v:=v-plist[i].extra;
        p:='#'+inttohex(v,2);
      end;

      pt_xminimm:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        v:=plist[i].extra - v;
        p:='#'+inttohex(v,2);
      end;

      pt_imm:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        if plist[i].optional and (plist[i].defvalue=v) then continue;

        p:='#'+inttohex(v,1);
      end;

      pt_simm:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        if plist[i].optional and (plist[i].defvalue=v) then continue;

        v:=SignExtend(v,highestbit(plist[i].maxval));

        p:='#'+inttohex(Int16(v),1);
      end;

      pt_pimm:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        if plist[i].optional and (plist[i].defvalue=v) then continue;


        p:='#'+inttohex(Int16(v),1);
      end;

      pt_fpimm8:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        try
          p:=FloatToStr(fp8tofloat(v));
        except
          p:='#'+inttohex(v,1);
        end;
      end;

      pt_scale:
      begin
        v:=(opcode shr plist[i].offset) and plist[i].maxval;
        p:='#'+inttohex(64-v,1);
      end;

      pt_imm_bitmask:
      begin
        qv:=armbitmask((opcode shr plist[i].offset) and plist[i].maxval, plist[i].extra);

        p:='#'+inttohex(qv,1);
      end;

      pt_prfop:
      begin
        v:=(opcode shr plist[i].offset) and $1f;
        case v of
          %00000: p:='PLDL1KEEP';
          %00001: p:='PLDL1STRM';
          %00010: p:='PLDL2KEEP';
          %00011: p:='PLDL2STRM';
          %00100: p:='PLDL3KEEP';
          %00101: p:='PLDL3STRM';
          %01000: p:='PLIL1KEEP';
          %01001: p:='PLIL1STRM';
          %01010: p:='PLIL2KEEP';
          %01011: p:='PLIL2STRM';
          %01100: p:='PLIL3KEEP';
          %01101: p:='PLIL3STRM';
          %10000: p:='PSTL1KEEP';
          %10001: p:='PSTL1STRM';
          %10010: p:='PSTL2KEEP';
          %10011: p:='PSTL2STRM';
          %10100: p:='PSTL3KEEP';
          %10101: p:='PSTL3STRM';
          else p:='%'+inttohex(v,1);
        end;
      end;

      pt_sysop_at:
      begin
        v:=(opcode shr plist[i].offset) and $3fff;
        case v of
          %00001111000000: p:='S1E1R';
          %10001111000000: p:='S1E2R';
          %11001111000000: p:='S1E3R';
          %00001111000001: p:='S1E1W';
          %10001111000001: p:='S1E2W';
          %11001111000001: p:='S1E3W';
          %00001111000010: p:='S1E0R';
          %00001111000011: p:='S1E0W';
          %10001111000100: p:='S12E1R';
          %10001111000101: p:='S12E1W';
          %10001111000110: p:='S12E0R';
          %10001111000111: p:='S12E0W';
        end;
      end;

      pt_sysop_dc:
      begin
        v:=(opcode shr plist[i].offset) and $3fff;
        case v of
          %01101110100001: p:='ZVA';
          %00001110110001: p:='IVAC';
          %00001110110010: p:='ISW';
          %01101111010001: p:='CVAC';
          %00001111010010: p:='CSW';
          %01101111011001: p:='CVAU';
          %01101111110001: p:='CIVAC';
          %00001111110010: p:='CISW';
        end;
      end;

      pt_sysop_ic:
      begin
        v:=(opcode shr plist[i].offset) and $3fff;
        case v of
          %00001110001000: p:='IALLUIS';
          %00001110101000: p:='IALLU';
          %01101110101001: p:='IVAU';
        end;
      end;

      pt_sysop_tlbi:
      begin
        v:=(opcode shr plist[i].offset) and $3fff;
        case v of
          %10010000000001: p:='IPAS2E1IS';
          %10010000000101: p:='IPAS2LE1IS';
          %00010000011000: p:='VMALLE1IS';
          %10010000011000: p:='ALLE2IS';
          %11010000011000: p:='ALLE3IS';
          %00010000011001: p:='VAE1IS';
          %10010000011001: p:='VAE2IS';
          %11010000011001: p:='VAE3IS';
          %00010000011010: p:='ASIDE1IS';
          %00010000011011: p:='VAAE1IS';
          %10010000011100: p:='ALLE1IS';
          %00010000011101: p:='VALE1IS';
          %10010000011101: p:='VALE2IS';
          %11010000011101: p:='VALE3IS';
          %10010000011110: p:='VMALLS12E1IS';
          %00010000011111: p:='VAALE1IS';
          %10010000100001: p:='IPAS2E1';
          %10010000100101: p:='IPAS2LE1';
          %00010000111000: p:='VMALLE1';
          %10010000111000: p:='ALLE2';
          %11010000111000: p:='ALLE3';
          %00010000111001: p:='VAE1';
          %10010000111001: p:='VAE2';
          %11010000111001: p:='VAE3';
          %00010000111010: p:='ASIDE1';
          %00010000111011: p:='VAAE1';
          %10010000111100: p:='ALLE1';
          %00010000111101: p:='VALE1';
          %10010000111101: p:='VALE2';
          %11010000111101: p:='VALE3';
          %10010000111110: p:='VMALLS12E1';
          %00010000111111: p:='VAALE1';
        end;
      end;

      pt_systemreg:
      begin
        v:=(opcode shr plist[i].offset) and $7fff;
        p:=IntToHex(v,4);
      end;

//      pt_vreg_T_size1or2:
      pt_vreg_T_sizenot3or0: //asumed that size is at offset 22 and q at offset 30
      begin
        v2:=(opcode shr 22 and 3);
        if (v2=3) or (v2=0) then exit(false); //invalid

        v2:=v2 or ((opcode shr (30-2)) and 4);


        v:=(opcode shr plist[i].offset) and $1f;
        p:='V'+inttostr(v)+'.'+getVectorSizeString(v2);
      end;

      pt_vreg_T_sizenot3: //asumed that size is at offset 22 and q at offset 30
      begin
        v2:=(opcode shr 22 and 3);
        if v2=3 then exit(false); //invalid

        v2:=v2 or ((opcode shr (30-2)) and 4);


        v:=(opcode shr plist[i].offset) and $1f;
        p:='V'+inttostr(v)+'.'+getVectorSizeString(v2);
      end;

      pt_vreg_B_1bit: //size is assumed to be at offset 22, q at 30
      begin
        p:='V'+inttostr(v)+'.';
        if ((opcode shr 22) and 3)<>0 then exit;
        if ((opcode shr 30) and 1)=0 then
          p:=p+'8B'
        else
          p:=p+'16B';
      end;

      pt_vreg_SD_2bit: //size is assumed to be at offset 22
      begin
        v2:=(opcode shr 22 and 1);
        v2:=v2 or (opcode shr (30-1)) and 2;
        v:=(opcode shr plist[i].offset) and $1f;

        p:='V'+inttostr(v)+'.';

        case v2 of
          0: p:=p+'2S';
          1: p:=p+'4S';
          2: exit(false);
          3: p:=p+'2D';
        end;

      end;

      pt_vreg_T: //size is assumed to be at offset 22
      begin
        v2:=(opcode shr 22 and 3);
        v2:=v2 or ((opcode shr (30-2)) and 4);
        v:=(opcode shr plist[i].offset) and $1f;
        p:='V'+inttostr(v)+'.'+getVectorSizeString(v2);
      end;

      pt_vreg_T2: //size is assumed to be at offset 22
      begin
        v2:=(opcode shr 22 and 3);
        v2:=v2 or ((opcode shr (30-2)) and 4);
        v:=(opcode shr plist[i].offset) and $1f;
        p:='V'+inttostr(v)+'.'+getVectorSizeString2(v2);
      end;

      pt_vreg_T2_AssumeQ1: //size is assumed to be at offset 22
      begin
        v2:=(opcode shr 22 and 3);
        v2:=v2 or 4; //assume Q is 1 (even if not)
        v:=(opcode shr plist[i].offset) and $1f;
        p:='V'+inttostr(v)+'.'+getVectorSizeString2(v2);
      end;

      pt_reglist_vector_specificsize: //size is provided in the extra field
      begin
        v:=(opcode shr plist[i].offset) and $1f;
        p:=getVectorRegisterListString(v, plist[i].extra, plist[i].maxval);
      end;

      pt_reglist_vector:    //maxval is the range (1,2,3 or 4)
      begin
        v:=(opcode shr plist[i].offset) and $1f; //the v reg is store at the offset of extra
        v2:=GetIMM2Value(plist[i].extra);  //size is stored in the extra bitfield  (q:size)

        getVectorRegisterListString(v, v2, plist[i].maxval);
      end;

      pt_reglist_vectorsingle:  //only the type
      begin
        v:=(opcode shr plist[i].offset) and $1f;
        v2:=GetIMM2Value(dword(plist[i].extra));
        v3:=(plist[i].extra shr 32) and $ff;
        if plist[i].maxval>1 then
          p:='{V'+inttostr(v)+'.'+chr(v3)+'-V'+inttostr((v+plist[i].maxval) mod 32)+'.'+chr(v3)+'}['+inttostr(v2)+']'
        else
          p:='{V'+inttostr(v)+'.'+chr(v3)+'}['+inttostr(v2)+']';
      end;

      pt_indexwidthspecifier:
      begin
        v:=(opcode shr plist[i].offset) and $3;
        if v=%11 then
          p:=p+'X'
        else
          p:=p+'W';

        v:=(opcode shr plist[i].extra) and $1f;
        p:=p+inttostr(v);
      end;

      pt_extend_amount:
      begin
        v:=(opcode shr plist[i].offset) and $7;
        case v of
          %010: p:='UXTW';
          %011: p:='LSL'; //ignored if default
          %110: p:='SXTW';
          %111: p:='SXTX';
        end;

        v2:=(opcode shr plist[i].extra) and 1; //s
        if (v2=0) and (v=%011) then continue; //not even a ,

        p:=p+' #'+inttostr(plist[i].maxval);
      end;



      pt_extend_amount_Extended_Register:
      begin
        v:=opcode shr plist[i].offset and 7;
        case v of
          %000: p:='UXTB';
          %001: p:='UXTH';
          %010:
          begin
            if ((opcode shr 31) and 1=0) and ((opcode and %11111)=%11111) or ((opcode and %1111100000)=%1111100000) then  //rd or rn==11111
              p:='LSL'
            else
              p:='UXTW';
          end;
          %011:
          begin
            if ((opcode shr 31) and 1=1) and ((opcode and %11111)=%11111) or ((opcode and %1111100000)=%1111100000) then  //rd or rn==11111
              p:='LSL'
            else
              p:='UXTX';
          end;
          %100: p:='SXTB';
          %101: p:='SXTH';
          %110: p:='SXTW';
          %111: p:='SXTX';
        end;

        v:=opcode shr plist[i].extra and 7;
        if (v>0) or (p='LSL') then
          p:=p+' #'+inttohex(v,1);

      end;


      pt_lslSpecific:
      begin
        v:=plist[i].offset;

        if v=1 then
          p:='LSL #'+inttohex(v,1);
      end;

      pt_mslSpecific:
      begin
        v:=plist[i].offset;

        if v=1 then
          p:='MSL #'+inttohex(v,1);
      end;


      pt_lsl0or12:
      begin
        v:=(opcode shr plist[i].offset) and 3;
        if plist[i].optional and (v=0) then continue;

        if v=1 then
          p:='LSL #C'
      end;

      pt_lsldiv16:
      begin
        v:=(opcode shr plist[i].offset) and 3;
        if plist[i].optional and (v=0) then continue;

        p:='LSL #'+inttohex(v*16,1);
      end;

      pt_shift16:
      begin
        v:=(opcode shr plist[i].offset) and 3;
        v2:=(opcode shr plist[i].extra) and $3f;

        case v of
          0: p:='LSL';
          1: p:='LSR';
          2: p:='ASR';
          3: p:='RESERVED';
        end;

        p:=p+' #'+inttohex(v2,1);
      end;

      pt_cond:
      begin
        v:=(opcode shr plist[i].offset) and $f;
        p:=ArmConditions[v];
      end;

      else
        p:=specialize IfThen<string>(i>0,', ','')+'NYI';
    end;

    if i>0 then
      LastDisassembleData.parameters:=LastDisassembleData.parameters+', ';

    if (not insideIndex) and (plist[i].index in [ind_index, ind_single, ind_singleexp]) then
    begin
      LastDisassembleData.parameters:=LastDisassembleData.parameters+'[';
      insideindex:=true;
    end;

    LastDisassembleData.parameters:=LastDisassembleData.parameters+p;


    if insideindex and (plist[i].index in [ind_single, ind_singleexp, ind_stop, ind_stopexp]) then
    begin
      LastDisassembleData.parameters:=LastDisassembleData.parameters+']';
      if plist[i].index in [ind_singleexp, ind_stopexp] then
        LastDisassembleData.parameters:=LastDisassembleData.parameters+'!';

      insideindex:=false;
    end;
  end;

end;

function TArm64Disassembler.ScanOpcodeList(const list: topcodearray): boolean;
var i: integer;
begin
  result:=false;
  for i:=0 to length(list)-1 do
  begin
    if ((opcode and list[i].mask)=list[i].value) and (list[i].use in [iuBoth, iuDisassembler]) then
    begin
      if list[i].alt<>nil then
      begin
        result:=ScanOpcodeList(list[i].alt^);
        if result then exit;
      end;

      LastDisassembleData.opcode:=list[i].mnemonic;

      //parse the parameters
      if ParseParameters(list[i].params) then
        exit(true);
      //else invalid parameters (alt's have param rules)
    end;
  end;
end;

function TArm64Disassembler.ScanGroupList(const list: TInstructionGroupArray):boolean;
var i: integer;
begin
  result:=false;
  for i:=0 to length(list)-1 do
  begin
    if (opcode and list[i].mask)=list[i].value then
    begin
      if list[i].listType=igpGroup then
        result:=ScanGroupList(PInstructionGroupArray(list[i].list)^)
      else
        result:=ScanOpcodeList(POpcodeArray(list[i].list)^);


      exit;
    end;
  end;
end;



function TArm64Disassembler.disassemble(var DisassembleAddress: ptruint{$ifdef armdev}; _opcode: dword{$endif}): string;
var
  x: ptruint;
  i: integer;
begin
  address:=DisassembleAddress;
  x:=0;
  setlength(LastDisassembleData.Bytes,4);

  {$ifdef armdev}
  PDWORD(@LastDisassembleData.Bytes[0])^:=_opcode;
  opcode:=_opcode;
  x:=4;
  {$else}
  readprocessmemory(processhandle, pointer(address), @LastDisassembleData.Bytes[0], 4, x);
  opcode:=pdword(@LastDisassembleData.Bytes[0])^;
  {$endif}

  LastDisassembleData.opcode:='UNDEFINED';
  Lastdisassembledata.parameters:='';
  LastDisassembleData.address:=address;
  LastDisassembleData.SeperatorCount:=0;
  LastDisassembleData.prefix:='';
  LastDisassembleData.PrefixSize:=0;
  LastDisassembleData.opcode:='';
  LastDisassembleData.parameters:='';
  lastdisassembledata.isjump:=false;
  lastdisassembledata.iscall:=false;
  lastdisassembledata.isret:=false;
  lastdisassembledata.isconditionaljump:=false;
  lastdisassembledata.modrmValueType:=dvtNone;
  lastdisassembledata.parameterValueType:=dvtNone;
  lastdisassembledata.Disassembler:=dcArm64;

  ScanGroupList(ArmGroupBase);


  result:=inttohex(LastDisassembleData.address,8);
  result:=result+' - ';
  if x>0 then
  begin
    for i:=0 to length(LastDisassembleData.bytes)-1 do
      result:=result+inttohex(LastDisassembleData.Bytes[i],2)+' ';
  end
  else
  begin
    for i:=0 to length(LastDisassembleData.bytes)-1 do
      result:=result+'?? ';
  end;

  result:=result+' - ';
  result:=result+LastDisassembleData.opcode;
  result:=result+' ';
  result:=result+LastDisassembleData.parameters;

  inc(DisassembleAddress,4);
end;

{$ifdef armdev}
procedure GetArmInstructionsAssemblerListDebug(r: tstrings);
var i,j: integer;
  x: string;
begin
  for i:=0 to ArmInstructionsAssemblerList.Count-1 do
  begin
    x:='';
    for j:=0 to length(popcode(ArmInstructionsAssemblerList.List[i]^.Data)^.params)-1 do
    begin
      if popcode(ArmInstructionsAssemblerList.List[i]^.Data)^.params[j].optional then
        x:='(has optional field)';
    end;
    r.add(inttostr(i)+'='+ArmInstructionsAssemblerList.List[i]^.Key+' - '+inttohex(ptruint(ArmInstructionsAssemblerList.List[i]^.Data),8)+'  '+x);
  end;


  r.add('');
  i:=ArmInstructionsAssemblerList.Find('MSR');
  r.add('MSR is at index '+inttostr(i));
  i:=ArmInstructionsAssemblerList.Find('CBZ');
  r.add('CBZ is at index '+inttostr(i));


end;
{$endif}

procedure FillArmInstructionsAssemblerListWithOpcodeArray(const list: TOpcodeArray);
var i: integer;
begin
  for i:=length(list)-1 downto 0 do
  begin
    if list[i].use=iuDisassembler then continue;

    ArmInstructionsAssemblerList.Add(list[i].mnemonic,@list[i]);
  end;
end;

procedure InitializeArmInstructionsAssemblerList;
begin
  ArmInstructionsAssemblerList:=TStringHashList.Create(true);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsCompareAndBranch);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsSystem);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsSYS_ALTS);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsConditionalBranchImm);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsExceptionGen);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsTestAndBranchImm);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsUnconditionalBranchImm);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsUnconditionalBranchReg);


  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreExlusive);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadRegisterLiteral);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreNoAllocatePairOffset);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterPairPostIndexed);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterPairOffset);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterPairPreIndexed);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterUnscaledImmediate);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterImmediatePostIndexed);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterUnprivileged);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterImmediatePreIndexed);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterRegisterOffset);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLoadStoreRegisterUnsignedImmediate);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDLoadStoreMultipleStructures);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDLoadStoreMultipleStructuresPostIndexed);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDLoadStoreSingleStructure);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDLoadStoreSingleStructurePostIndexed);

  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsPCRelAddressing);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAddSubtractImm);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLogicalImm);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsMoveWideImm);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsBitField);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsExtract);


  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsLogicalShiftedRegister);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAddSubtractShiftedRegister);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAddSubtractExtendedRegister);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAddSubtractWithCarry);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsConditionalCompareRegister);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsConditionalCompareImmediate);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsCondionalSelect);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsDataProcessing3Source);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsDataProcessing2Source);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsDataProcessing1Source);


  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPoint_FixedPointConversions);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPointConditionalCompare);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPointDataProcessing2Source);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPointConditionalSelect);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPointImmediate);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPointCompare);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPointDataProcessing1Source);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPoint_IntegerConversions);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsFloatingPointDataProcessing3Source);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDThreeSame);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDThreeDifferent);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDTwoRegMisc);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDAcrossLanes);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDCopy);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDVectorXIndexedElement);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDModifiedImmediate);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDShiftByImmediate);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDTBLTBX);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDZIPUNZTRN);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDEXT);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDScalarThreeSame);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDScalarThreeDifferent);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDScalarTwoRegMisc);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDScalarPairwise);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDScalarCopy);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDScalarXIndexedElement);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsAdvSIMDScalarShiftByImmediate);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsCryptoAES);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsCryptoThreeRegSHA);
  FillArmInstructionsAssemblerListWithOpcodeArray(ArmInstructionsCryptoTwoRegSHA);

end;


procedure InitARM64Support;
const initialized: boolean=false;
begin
  if not initialized then
  begin
    InitializeArmInstructionsAssemblerList;
    initialized:=true;
  end;
end;


end.

