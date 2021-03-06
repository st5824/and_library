unit ProcessUnit;

interface
uses Windows, SysUtils;

const
  HASH_ProceIsStillValid     = $0AA7BB64;
  HASH_ProceIsValid          = $0BDD7744;
  HASH_ProceIsListing        = $07DF1717;
  HASH_GetModuleMD5          = $0D3A1345;
  HASH_ProceIDToName         = $0D015D95;

  HASH_EnumerateProcess      = $04D1B183;
  HASH_EnumerateProceDllFuns = $095DA313;
  HASH_EnumerateProceHandles = $0C2FAB83;
  HASH_EnumerateProceWindows = $0BAFAFD3;
  HASH_EnumerateProceLocalFiles = $05B9D703;


Type
  TEmuProcess      = Procedure (ProcID: DWORD; ExeFile: PChar);stdcall;
  TEmuProceDllFuns = Procedure (DLLName, FuncName: PChar);stdcall;
  TEmuProceHandles = Procedure (nType: Integer; TypeStr, HandleName: PChar);stdcall;
  TEmuProceWindows = Procedure (Caption, ClassName: PChar);stdcall;
  TEmuProceLocals  = Procedure (FileName: PChar); stdcall;

Procedure EnumerateProcess(EumPro: TEmuProcess);stdcall;
Procedure EnumerateProceDllFuns(ProcID: DWORD; EumPro: TEmuProceDllFuns);stdcall;
Procedure EnumerateProceHandles(ProcID: DWORD; EumPro: TEmuProceHandles);stdcall;
Procedure EnumerateProceWindows(ProcID: DWORD; EumPro: TEmuProceWindows);stdcall;
Procedure EnumerateProceLocalFiles(ProcID: DWORD; EumPro: TEmuProceLocals);stdcall;

Function  ProceIsStillValid(ProcID: DWORD):LongBool;stdcall;
Function  ProceIsValid(ProcName: PChar):LongBool;stdcall;
Function  ProceIsListing(ProcName: PChar):LongBool;stdcall;
Function  GetModuleMD5(ProcName, ModuleName: PChar):PChar;stdcall;
Function  ProceIDToName (ProcID: DWORD): PChar; stdcall;
Function  IsMainExeCodeAddr(CodeAddr: Pointer):LongBool;stdcall;
Function  GetSectionMemory (SectionName: PChar; var CodeBase: Pointer; var CodeSize: Integer):LongBool;stdcall;

implementation

uses madKernel, madShell,  madRemote, TlHelp32, md5;

var
  OutMd5Str: string;

type
  LPTSectionArray = ^TSectionArray;
  TSectionArray = array[byte] of TImageSectionHeader;

function GetSections(iProc: IProcess; iModl: IModule; var NumberOfSection: Integer):LPTSectionArray;
var
  ImageBase: array[0..1023] of char;
  ImageDosHeader: PImageDosHeader;
  ImageNtHeaders: PImageNtHeaders;
  NtHeaderOffset, SectionOffset, SectionHeadSize: WORD;
begin
  iProc.ReadMemory(iModl.Memory^, ImageBase[0], 1024);
  ImageDosHeader := @ImageBase[0];
  NtHeaderOffset := ImageDosHeader._lfanew;
  ImageNtHeaders := @ImageBase[NtHeaderOffset];
  NumberOfSection := ImageNtHeaders.FileHeader.NumberOfSections;

  SectionOffset := NtHeaderOffset + ImageNtHeaders.FileHeader.SizeOfOptionalHeader + SizeOf(TImageFileHeader) + SizeOf(DWORD);

  SectionHeadSize := NumberOfSection * SizeOf(TImageSectionHeader);
  GetMem(Result, SectionHeadSize);
  CopyMemory(Result, @ImageBase[SectionOffset], SectionHeadSize);
end;

function _GetSections(ModuleHandle: THandle; var NumberOfSection: Integer):LPTSectionArray;
var
  ImageBase: array[0..1023] of char;
  ImageDosHeader: PImageDosHeader;
  ImageNtHeaders: PImageNtHeaders;
  NtHeaderOffset, SectionOffset, SectionHeadSize: WORD;
begin
  CopyMemory (@ImageBase[0], Pointer(ModuleHandle), 1024);
  ImageDosHeader := @ImageBase[0];
  NtHeaderOffset := ImageDosHeader._lfanew;
  ImageNtHeaders := @ImageBase[NtHeaderOffset];
  NumberOfSection := ImageNtHeaders.FileHeader.NumberOfSections;

  SectionOffset := NtHeaderOffset + ImageNtHeaders.FileHeader.SizeOfOptionalHeader + SizeOf(TImageFileHeader) + SizeOf(DWORD);

  SectionHeadSize := NumberOfSection * SizeOf(TImageSectionHeader);
  GetMem(Result, SectionHeadSize);
  CopyMemory(Result, @ImageBase[SectionOffset], SectionHeadSize);
end;

Function  IsMainExeCodeAddr(CodeAddr: Pointer):LongBool;stdcall;
var
  iProc: IProcess;
  iModl: IModule;
  SectionBase: LPTSectionArray;
  SectionHeader: PImageSectionHeader;
  SectionCount, I: Integer;
  SectName: String;
  CodeBase: Pointer;
  CodeSize: Integer;
begin
  Result := False;
  iProc := CurrentProcess;
  iModl := iProc.MainModule;

  SectionBase := GetSections(iProc, iModl, SectionCount);
  if not assigned (SectionBase) then exit;

  for I := 0 to SectionCount -1 do
  begin
    SectionHeader := @SectionBase[I];
    SectName := UpperCase(StrPas(@SectionHeader.Name[0]));

    CodeBase := POINTER( iModl.HInstance + SectionHeader.VirtualAddress);
    CodeSize := SectionHeader.SizeOfRawData;

    if (SectName = '.TEXT') or (SectName = 'CODE') then
      if DWORD(CodeAddr) > DWORD(CodeBase) then
        if DWORD(CodeAddr) < (DWORD(CodeBase)+DWORD(CodeSize)) then
          Result := True;
  end;

  FreeMem(SectionBase);
end;

Function GetSectionMemory (SectionName: PChar; var CodeBase: Pointer; var CodeSize: Integer):LongBool;stdcall;
var
  iProc: IProcess;
  iModl: IModule;
  SectionBase: LPTSectionArray;
  SectionHeader: PImageSectionHeader;
  SectionCount, I: Integer;
  SectName: String;
begin
  Result := False;
  iProc := CurrentProcess;
  iModl := iProc.MainModule;

  SectionBase := GetSections(iProc, iModl, SectionCount);
  
  if assigned (SectionBase) then
  begin
    for I := 0 to SectionCount -1 do
    begin
      SectionHeader := @SectionBase[I];
      SectName := UpperCase(StrPas(@SectionHeader.Name[0]));

      if SectName = StrPas(SectionName) then
      begin
        CodeBase := POINTER( iModl.HInstance + SectionHeader.VirtualAddress);
        CodeSize := SectionHeader.SizeOfRawData;
        Result := True;
        Exit;
      end;
    end;
  end;

  FreeMem(SectionBase);
end;

Function  GetModuleMD5(ProcName, ModuleName: PChar):PChar;stdcall;
var
  iProc: IProcess;
  iModl: IModule;
  SectionBase: LPTSectionArray;
  SectionHeader: PImageSectionHeader;
  SectionCount, I: Integer;
  SectName: String;
  CodeBase, CodeMem: Pointer;
  CodeSize: Integer;
  Context: MD5Context;
  Digest: MD5Digest;
begin
  Result := nil;
  OutMd5Str := '';

  if ProcName = nil then exit;

  iProc := Process(StrPas(ProcName));
  if not iProc.IsStillValid then exit;

  if ModuleName = NIL then
    iModl := iProc.MainModule
  else
    iModl := iProc.Module(StrPas(ModuleName));

  if not iModl.IsValid then exit;

  SectionBase := GetSections(iProc, iModl, SectionCount);
  if not assigned (SectionBase) then exit;

  MD5Init(Context);
  for I := 0 to SectionCount -1 do
  begin
    SectionHeader := @SectionBase[I];
    SectName := UpperCase(StrPas(@SectionHeader.Name[0]));

    CodeBase := POINTER( iModl.HInstance + SectionHeader.VirtualAddress);
    CodeSize := SectionHeader.SizeOfRawData;

    if (SectName = '.TEXT') or (SectName = 'CODE') or (SectName = '.RSRC') then
    begin
      CodeMem := AllocMem(CodeSize);
      iProc.ReadMemory(CodeBase^, CodeMem^, CodeSize);
      MD5Update(Context, CodeMem, CodeSize);
      FreeMem(CodeMem);
    end;
  end;                                            
  MD5Final(Context, Digest);
  OutMd5Str := MD5Print(Digest);

  FreeMem(SectionBase);
  if OutMd5Str = '' then exit;                  
                                                 
  OutMd5Str := UpperCase(OutMd5Str);
  Result := @OutMd5Str[1];                       
end;

var
  TmpProceName: string;

Function  ProceIDToName (ProcID: DWORD): PChar; stdcall;
begin
  TmpProceName := Process (ProcID).ExeFile;
  Result := PChar(TmpProceName);
end;

Procedure _EnumerateProcess(EumPro: TEmuProcess);stdcall;
var
  I: integer;
  pl : TDAProcess;
begin
  pl := EnumProcesses;
  for I := 0 to high(pl) do
    EumPro(pl[I].id, PChar(pl[I].exeFile));
end;

Procedure EnumerateProcess(EumPro: TEmuProcess);stdcall;
var
  iProcs: IProcesses;
  iProc: IProcess;
  I: Integer;
begin
  iProcs := Processes;
  for i := 0 to iProcs.ItemCount - 1 do
  begin
    iProc := iProcs.Items[I];     
    EumPro(iProc.ID,  @iProc.ExeFile[1]);
  end;
end;


Procedure __EnumerateProcess(EumPro: TEmuProcess);stdcall;
var
  ContinueLoop: BOOL;
  FSnapshotHandle: THandle;
  FProcessEntry32: TProcessEntry32;
begin
  FSnapshotHandle := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  FProcessEntry32.dwSize := SizeOf(FProcessEntry32);
  ContinueLoop := Process32First(FSnapshotHandle, FProcessEntry32);
  while Integer(ContinueLoop) <> 0 do
  begin
    EumPro(FProcessEntry32.th32ProcessID, FProcessEntry32.szExeFile);
    ContinueLoop := Process32Next(FSnapshotHandle, FProcessEntry32);
  end;
  CloseHandle(FSnapshotHandle);
end;

procedure SearchFile(UpperBase, Path:string; EumPro: TEmuProceLocals);
var
  SearchRec:TSearchRec;
  found:integer;
  FileName, DirName: String;
  UpperFile: String;
begin
  if not DirectoryExists(Path) then exit;
  found:=FindFirst(path+'*.*', faAnyFile, SearchRec);
  while found=0 do
  begin
    sleep(1);
    if (SearchRec.Name<>'.') and (SearchRec.name<>'..') and (SearchRec.Attr = faDirectory) then
    begin
      DirName := Path + SearchRec.Name + '\';
      SearchFile(UpperBase, DirName, EumPro);
    end  else
    begin
      FileName := Path + SearchRec.Name;
      if FileExists(FileName) then
      begin
        UpperFile := UpperCase(FileName);
        if CompareMem(@UpperBase[1], @FileName[1], Length(UpperBase)) then
          EumPro(@FileName[Length(UpperBase)]);
      end;
    end;
    found:=FindNext(SearchREc);
  end;
  FindClose(SearchRec);
end;


Function  ProceIsStillValid(ProcID: DWORD):LongBool;stdcall;
begin
  Result := Process(ProcID).IsStillValid;
end;

Function  ProceIsValid(ProcName: PChar):LongBool;stdcall;
begin
  Result := Process(StrPas(ProcName)).IsValid;
end;

Function  ProceIsListing(ProcName: PChar):LongBool;stdcall;
var
  I : integer;
  pl : TDAProcess;
  FileName,CmpProcName: String;
begin
  result := False;
  CmpProcName := UpperCase(StrPas(ProcName));
  
  pl := EnumProcesses;
  for I := 0 to high(pl) do
  begin
    FileName := UpperCase(ExtractFileName(pl[I].exeFile));
    if FileName = CmpProcName then
    begin
      Result := True;
      exit;
    end;
  end;
end;

Function  ProceMainFormIsActive(ProcName: PChar):LongBool;stdcall;
begin
  Result := Process(StrPas(ProcName)).IsValid;
end;

procedure EnumerateProceLocalFiles(ProcID: DWORD; EumPro: TEmuProceLocals);stdcall;
var
  iProc: IProcess;
  MainPath, SysPath, WinPath: String;
begin
  iProc := Process(ProcID);
  if not iProc.IsStillValid then exit;

  SysPath := UpperCase(SysFolder);
  WinPath := UpperCase(WinFolder);
  MainPath := UpperCase(ExtractFilePath(iProc.MainModule.FileName));

  if Length(MainPath) > 4 then
  if not CompareMem(@MainPath[1], @SysPath[1], Length(SysPath)) then
  if not CompareMem(@MainPath[1], @WinPath[1], Length(WinPath)) then
    SearchFile(MainPath, MainPath, EumPro);
end;

procedure EnumerateProceDllFuns(ProcID: DWORD; EumPro: TEmuProceDllFuns);stdcall;
var
  iProc: IProcess;
  iMods: IModules;
  iMod : IModule;
  ExportList: IXxportList;
  ExportEntry: IExportEntry;
  I, J, MainPathLength: Integer;
  MainPath, WinPath, SysPath, FileName, FileExt: String;
begin
  iProc := Process(ProcID);
  if not iProc.IsStillValid then exit;
  SysPath := UpperCase(SysFolder);
  WinPath := UpperCase(WinFolder);
  MainPath := UpperCase(ExtractFilePath(iProc.MainModule.FileName));
  MainPathLength := Length(MainPath);
  iMods := iProc.Modules;
  for I := 0 to iMods.ItemCount - 1 do
  begin
    sleep(1);
    iMod := iMods.Items[I];
    FileName := UpperCase(iMod.FileName);

    FileExt := UpperCase(ExtractFileExt(FileName));
    if FileExt = '.BPL' then continue;
    if CompareMem(@FileName[1], @SysPath[1], Length(SysPath)) then continue;
    if CompareMem(@MainPath[1], @WinPath[1], Length(WinPath)) then continue;

    if CompareMem(@FileName[1], @MainPath[1], Length(MainPath)) then
    begin
      ExportList := iMod.ExportList;
      try
        for J := 0 to ExportList.ItemCount - 1 do
        begin
          sleep(1);
          ExportEntry := ExportList.Items[J];
          EumPro(@iMod.FileName[MainPathLength], @ExportEntry.Name[1]);
        end;
      except
        OutputDebugString('EnumerateProceDllFuns Exception');
      end;
    end;
  end;
end;

procedure EnumerateProceHandles(ProcID: DWORD; EumPro: TEmuProceHandles);stdcall;
var
  iProc: IProcess;
  iHdls: IHandles;
  I: Integer;
begin
  iProc := Process(ProcID);
  if not iProc.IsStillValid then exit;   

  iHdls := iProc.Handles;

  try
    for I := 0 to iHdls.ItemCount - 1 do
    begin
      sleep(1);
//      outputdebugstring(PChar('---- Access = $'+IntToHEx(iHdls.Items[I].Access, 8)));

      if (iHdls.Items[I].Access and $FFFF) = $019F then continue;

      with iHdls.Items[I].KernelObj do
      begin
        if ObjName = '' then continue;
        EumPro (Integer(ObjType), @ObjName[1], @ObjTypeStr[1]);
        if not iProc.IsStillValid then break;
      end;

    end;
  except
    OutputDebugString('EnumerateProceHandles Exception');
  end;
end;

procedure EnumChildWndProc(AhWnd:LongInt; AlParam:lParam);stdcall;
var
  EumPro: TEmuProceWindows absolute AlParam;
  WndClassName: array[byte] of Char;
  WndCaption: PChar;
  WndCaptionLen: Integer;
begin
  GetClassName(AhWnd,wndClassName,HIGH(byte));

  WndCaptionLen := GetWindowTextLength(aHwnd);
  if WndCaptionLen = 0 then exit;
  GetMem(WndCaption,WndCaptionLen+ 64);
  GetWindowText(aHwnd,WndCaption,WndCaptionLen+ 64);

  EumPro(WndCaption, wndClassName);

  FreeMem(WndCaption);
end;

procedure EnumerateProceWindows(ProcID: DWORD; EumPro: TEmuProceWindows);stdcall;
var
  iProc: IProcess;
  iWnds: IWindows;
  iWnd: IWindow;
  I: Integer;
begin
  iProc := Process(ProcID);
  if not iProc.IsStillValid then exit;

  try
    iWnds := iProc.Windows_;
    for I := 0 to iWnds.ItemCount - 1 do
    begin
      sleep(1);
      iWnd := iWnds.Items[I];
      EumPro (@iWnd.Text[1], @iWnd.ClassName[1]);
      EnumChildWindows(iWnd.Handle, @EnumChildWndProc, Longint(@EumPro));
      if not iProc.IsStillValid then break;
    end;
  except
    OutputDebugString('EnumerateProceWindows Exception');
  end;
end;


end.
