Type
  //ģ���־
  LPTCodeMark = ^TCodeMark;
  TCodeMark = Packed Record
    SIGN: Array[0..15] of char;
    MOD_NAME: array[0..15] of char;
    LOAD_POS: array[0..15] of char;
  end;

  ////////////////////////////
  ///  DLL ����ֵ�ص�
  TResultCallBack = function (InstDLL : THandle; Track : Pointer; RunRet : Pointer; RunRetLen : LongWord) : Integer; stdcall;
  TGetProcedureAddrss = function (LibNameCRC, FuncNameCRC: LongWord): POINTER; stdcall;