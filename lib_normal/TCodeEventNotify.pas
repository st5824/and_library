unit TCodeEventNotify;

interface
uses
   windows,classes, sysutils;

{$I Hook.inc}

const
   MAX_HOOK_COUNT=16;
   CODE_BUFFER_SIZE=128;    
   DEFAULT_REGIST_LENGTH = SizeOf(TRegInfo);

type      
   PTHookRecord=^THookRecord;
   THookRecord=packed record
     Hook       :packed record
                        pHookAddress     :pointer;    //钩子起始地址
                        pJumpBackAddress :pointer;    //钩子返回地址
                        fnCallBack       :pointer;    //回调函数返回寄存器状态
                end;
     RegInfo    :TRegInfo;
     szCodeBuffer:array[0..CODE_BUFFER_SIZE-1] of char;
   end;

   THookInfo = packed record
       Hooks:array[0..MAX_HOOK_COUNT-1] of THookRecord;
       count:word;
   end;

   THookInfoCtrl=class
     private
       FHookInfo:THookInfo;
       FDebugPrint :Boolean;
     protected
       function GetHooksCount:word;
       procedure DebugView(str:string);
     public
       property HooksCount:word read GetHooksCount;
       property DebugPrint:Boolean read FDebugPrint write FDebugPrint;
       
       function AddHookInfo     (pHookAddress     :pointer;
                                 pJumpBackAddress :pointer;
                                 fnCallBack       :pointer):PTHookRecord;
       function DeleteHookInfo  (pHookAddress   :pointer        ):boolean;
       function GetHookInfo     (pHookAddress   :pointer        ):PTHookRecord;
       procedure Clear;
   end;

   THookCodePacket=class(TObject)
     private
       FpBlockHead_Template     :pointer;
       FdwBlockLength_Template   :dword;
       FdwBlockCallOffset_Template   :dword;
       FHookInfoCtrl:THookInfoCtrl;
       FDbgSwitch :LongBool;
     protected
       procedure DebugView(str:string);
       procedure DbgViewAsHex(buf:pchar; len:word);

       function WriteMem(pAddress:pointer; pBuf:pointer; dwLen:dword):boolean;
       function SetJumpCode(HookRecord:PTHookRecord):boolean;
       function GetAllHooks(var ls:TList):boolean; 
       function MakePatch(HookRecord:PTHookRecord):boolean;
       function SetCallBackOffset(HookRecord:PTHookRecord):boolean;
       function FindPatchBlock   (pTemplate:pointer; var pPatchHead:pointer;  var wPatchLen:word):boolean;
       function FindBeHookedCodeHead(pHookRecord:PTHookRecord):pointer;
       function StartHook(HookRecord:PTHookRecord):boolean;
     public
       function SetHook  (pHookAddress     :pointer;
                          pJumpBackAddress :pointer;
                          fnCallBack       :pointer;
                          fnCanBeHook      :TCheckCanBeHook = Nil):boolean;
       function UnHook   (pHookAddress:pointer):boolean;
       function IsHooking(pHookAddress:pointer):boolean;
       procedure ClearHook;
       function Count:integer;
       procedure DebugPrint(Switch:LongBool=True);
       constructor Create;
       destructor Destroy; override;
   end;

function WriteMemory(pAddress:pointer; pBuf:pointer; dwLen:dword):LongBool; stdcall;
function GetCallingImage: THandle; Register;
function GetCallingAddr: Pointer; Register;

function SetHook (HookAddress, JumpBackAddress, fnCallBack, fnCanBeHook : Pointer): LongBool; stdcall;
function UnHook (HookAddress: pointer): LongBool; stdcall;

implementation

var
  HK: THookCodePacket;

function GetCallingImage: THandle; Register;
asm
    mov eax, ebp
    add eax, 4
    mov eax, [eax]
    and eax, $FFFFF000
    jmp @CmpImage
  @NextAddr:
    sub eax, $1000
  @CmpImage:
    cmp word ptr [eax], $5A4D
    jnz @NextAddr
end;

function GetCallingAddr: Pointer; Register;
asm
    mov eax, ebp
    add eax, 4
    mov eax, [eax]
end;

function SetHook  (HookAddress, JumpBackAddress, fnCallBack, fnCanBeHook : Pointer): LongBool; stdcall;
begin
  Result := False;
  
  if not assigned (HK) then
    HK := THookCodePacket.Create;

  if HK.IsHooking (HookAddress) then exit;

  Result := HK.SetHook(HookAddress, JumpBackAddress, fnCallBack, fnCanBeHook);
end;

function UnHook(HookAddress: pointer): LongBool; stdcall;
begin
  if not assigned (HK) then
    HK := THookCodePacket.Create;
  Result := HK.UnHook(HookAddress);
end;


function WriteMemory(pAddress:pointer; pBuf:pointer; dwLen:dword):LongBool; stdcall;
var
   mbi_thunk:MEMORY_BASIC_INFORMATION;
   dwOldProtect:dword;
begin
    result:=false;

    //内容相同，不需要写入
    if CompareMem (pAddress, pBuf, dwLen) then
    begin
      Result := True;
      Exit;
    end;
             
    //查询内存属性
    if 0 = VirtualQuery(pAddress, mbi_thunk, sizeof(MEMORY_BASIC_INFORMATION)) then
    begin
      Exit;
    end;

    //该内存可直接写入
    if (mbi_thunk.Protect = PAGE_READWRITE) or
       (mbi_thunk.Protect = PAGE_EXECUTE_READWRITE) then
    begin
      CopyMemory(pAddress, pBuf, dwLen);
      Result := True;
      Exit;
    end;

    //该内存需修改属性后才能写入
    if VirtualProtect( mbi_thunk.BaseAddress, mbi_thunk.RegionSize, PAGE_EXECUTE_READWRITE,@mbi_thunk.Protect) then
    begin
      CopyMemory(pAddress, pBuf, dwLen);
      if VirtualProtect( mbi_thunk.BaseAddress, mbi_thunk.RegionSize, mbi_thunk.Protect,@dwOldProtect) then
      begin
        result:=true;
        Exit;
      end;   
    end;

    //该内存需特别途径才能成功写入

    
end;

procedure THookCodePacket.DebugPrint(Switch:LongBool=True);
begin
  FDbgSwitch:=Switch;
  FHookInfoCtrl.DebugPrint := Switch;
end;

function THookCodePacket.Count:integer;
begin
  result := FHookInfoCtrl.HooksCount;
end;

procedure THookCodePacket.DebugView(str:string);
begin
  if FDbgSwitch then
    OutputDebugString(pchar(str));
end;

procedure THookCodePacket.DbgViewAsHex(buf:pchar; len:word);
var
  i:integer;
  str:string;
begin
  str:='';
  for i:=0 to len-1 do
    str:=str+inttohex(ord(buf[i]), 2)+' ';
  DebugView(str);
end;

procedure GetTemplateInfo(ppHead:PPointer; dwLen:PDWORD; dwCallOffset:PDWORD);stdcall;
asm
        PUSHAD
        CALL    @GetHeadAndLength
  @BlockBase:
        PUSHAD        // <----------------------------------------

        CALL    @GetRegInfo
  @GetRegInfo:
        POP     EBX
        MOV     EAX, OFFSET @GetRegInfo
        SUB     EAX, OFFSET @BlockBase
        SUB     EBX, EAX
        SUB     EBX, DEFAULT_REGIST_LENGTH

        MOV     ESI, ESP
        MOV     EDI, EBX
        MOV     ECX, 8
        CLD
        REP     MOVSD

        PUSHFD
        PUSHAD
        PUSH    EBX
        JMP     @StartCall
  @GetCallOffset:
        CALL    @EndPro
  @StartCall:
        DB      $E8        //调用处理过程   e8 00 00 00 00
        DD      $00000000
        POPAD
        POPFD

        MOV     ESI, EBX
        MOV     EDI, ESP
        MOV     ECX, 8
        CLD
        REP     MOVSD

        POPAD         // <----------------------------------------
  @GetHeadAndLength:
        POP     EBX
        MOV     EAX, ppHead
        MOV     [EAX], EBX

        MOV     EAX, OFFSET @GetHeadAndLength
        SUB     EAX, EBX
        MOV     EDX, dwLen
        MOV     [EDX], EAX
        JMP     @GetCallOffset
  @EndPro:
        POP     EAX
        INC     EAX
        SUB     EAX, EBX  
        MOV     EBX, dwCallOffset
        MOV     [EBX], EAX
        POPAD
end;


constructor THookCodePacket.Create;
begin
   inherited Create;
   GetTemplateInfo(@FpBlockHead_Template, @FdwBlockLength_Template, @FdwBlockCallOffset_Template);
   FHookInfoCtrl:=THookInfoCtrl.Create;
   FDbgSwitch:=False;
   FHookInfoCtrl.DebugPrint := False;
end;

destructor THookCodePacket.destroy;
begin
    ClearHook;
    FHookInfoCtrl.Free;
    inherited Destroy;
end;

function THookCodePacket.GetAllHooks(var ls:TList):boolean;
var
  i:integer;
begin
   result:=false;
   ls.Clear;
   if FHookInfoCtrl.HooksCount=0 then exit;
   for i:=0 to FHookInfoCtrl.HooksCount-1 do
   begin
      ls.Add(FHookInfoCtrl.FHookInfo.Hooks[i].Hook.pHookAddress);
   end;
   result:=true;
end;

function THookCodePacket.IsHooking(pHookAddress:pointer):boolean;
var
   ls:Tlist;
   i:integer;
begin
   result:=false;
   if Not Assigned(pHookAddress) then exit;

   ls:=Tlist.Create;
   if not GetAllHooks(ls) then exit;       
   if ls.Count=0 then exit;
   for i:=0 to ls.Count-1 do
   begin
       if pHookAddress=ls[i] then
       begin
           result:=true;
           exit;
       end;
   end;
end;

procedure THookCodePacket.ClearHook;
var
  i:integer;
  ls:TList;
begin
    ls:=TList.Create;
    GetAllHooks(ls);

    for i:=0 to  ls.Count-1 do
    begin
        UnHook(ls[i]);
    end;

    FHookInfoCtrl.Clear;
    ls.Free;
end;


//=======================================================
//修正调用函数Call偏移地址的指针
function THookCodePacket.SetCallBackOffset(HookRecord:PTHookRecord):boolean;
var
  pCallOffset:pointer;
  nCallOffset:integer;
begin
    result:=false;
    try
      pCallOffset :=pointer(dword(@HookRecord.szCodeBuffer[0]) + FdwBlockCallOffset_Template);
      if pCallOffset=nil then exit;
      if PDWORD(pCallOffset)^ <> 0 then exit;

      //计算Call偏移值
      nCallOffset:=dword(HookRecord.Hook.fnCallBack)-dword(pCallOffset)-4;
      //填入Call偏移值
      PLongInt(pCallOffset)^:=nCallOffset;
    except
      exit;
    end;
    result := TRue;
end;       

function THookCodePacket.FindPatchBlock(pTemplate:pointer;
                         var pPatchHead:pointer;
                         var wPatchLen:word):boolean;
const
  MAX_SEARCH_LENGTH=CODE_BUFFER_SIZE;
var
  i:integer;
  bFlag:byte;
  pTemplateScr:pchar;
  pPatchTail:pointer;
begin
  result:=true;
  try
    pTemplateScr:=pTemplate;
    bFlag:=0;
    pPatchHead:=nil;
    wPatchLen:=0;
    for i:=0 to MAX_SEARCH_LENGTH-1 do
    begin
        if ord(pTemplateScr[i])=$40 then
        if ord(pTemplateScr[i+1])=$48 then
        begin
            case bFlag of
            0:begin
                  pPatchHead:=@pTemplateScr[i+2];
                  bFlag:=1;
              end;
            1:begin
                  pPatchTail:=@pTemplateScr[i];
                  wPatchLen:= dword(pPatchTail) - dword(pPatchHead);
                  break;
              end;
            end;

        end;
    end;
  except
    result:=false;
  end;
end;

function THookCodePacket.MakePatch(HookRecord:PTHookRecord):boolean;
var
  pAim:pointer;

  wHookBlockLen:word;

  pJmpOffset:pointer;
  nJmpOffset:integer;  
begin
    result:=false;
//===========================================================//
//构造自定义补丁块

    //=======================================================
    //复制补丁块模板
    pAim:=@HookRecord.szCodeBuffer[0];
    copymemory(pAim, FpBlockHead_Template, FdwBlockLength_Template);

    //修正调用函数Call偏移地址的指针
    if not SetCallBackOffset(HookRecord) then
    begin
       DebugView('SetCallBackOffset failure!!');
       exit;
    end;

//========================================================================
//复制被Hook块
    
    inc(dword(pAim),FdwBlockLength_Template);
    wHookBlockLen:=word(dword(HookRecord.Hook.pJumpBackAddress)-dword(HookRecord.Hook.pHookAddress));
    copymemory(pAim, HookRecord.Hook.pHookAddress, wHookBlockLen);

//========================================================================
//构造Jump指令,返回原代码段
    
    inc(dword(pAim),wHookBlockLen);
    PBYTE(pAim)^:=$E9;
    inc(dword(pAim),1);
    pJmpOffset:=pAim;
    //计算Jmp偏移值
    nJmpOffset:=dword(HookRecord.Hook.pJumpBackAddress)-dword(pJmpOffset)-4;
    //填入Jmp偏移值
    PLongInt(pJmpOffset)^:=nJmpOffset;   

    DebugView('MakePatch completely!!');

    result:=true;
end;


//=============写入Jmp命令到被Hook内存块首，使之向自定义memory跳转========================//
function THookCodePacket.StartHook(HookRecord:PTHookRecord):boolean;
var
   JmpOffset:integer;
   JmpToMyMem:array[0..4] of char;
begin
    //JmpToMyMem   偏移地址＝copy的内存块首地址－被Hook地址－指令长度5
    JmpOffset:= dword(@HookRecord.szCodeBuffer)-dword(HookRecord.Hook.pHookAddress)-5;
    //构造jmp命令
    JmpToMyMem[0]:=char($E9);
    PLongInt(@JmpToMyMem[1])^:=JmpOffset;
    //挂钩
    result:=writemem( HookRecord.Hook.pHookAddress, @JmpToMyMem[0],5);
end;

function THookCodePacket.SetJumpCode(HookRecord:PTHookRecord):boolean;
begin
    result:=false;
    if HookRecord=nil then exit;

    if not MakePatch(HookRecord) then exit;

    if not StartHook(HookRecord) then exit;

    Result := True;
//==================== debug view ======================================================//
    DebugView('SetJumpCode successfully!');
end;

function THookCodePacket.WriteMem(pAddress:pointer; pBuf:pointer; dwLen:dword):boolean;
var
   mbi_thunk:MEMORY_BASIC_INFORMATION;
   dwOldProtect:dword;
begin
    result:=false;
    virtualQuery(pAddress, mbi_thunk, sizeof(MEMORY_BASIC_INFORMATION));
    if not virtualProtect( mbi_thunk.BaseAddress, mbi_thunk.RegionSize, PAGE_READWRITE,@mbi_thunk.Protect) then exit;
    copymemory(pAddress, pBuf, dwLen);
    if not virtualProtect( mbi_thunk.BaseAddress, mbi_thunk.RegionSize, mbi_thunk.Protect,@dwOldProtect) then exit;
    result:=true;
end;

function THookCodePacket.SetHook  (pHookAddress     :pointer;
                                   pJumpBackAddress :pointer;
                                   fnCallBack       :pointer;
                                   fnCanBeHook      :TCheckCanBeHook = Nil):boolean;
var
  pHook:PTHookRecord;
  temp:string;
begin
    result:=false;
    if not assigned(pHookAddress) then exit;
    if not assigned(pJumpBackAddress) then exit;
    if not assigned(fnCallBack) then exit;
    if (dword(pJumpBackAddress) - dword(pHookAddress) > CODE_BUFFER_SIZE) then exit;
    if assigned(fnCanBeHook) then
      if not fnCanBeHook (pHookAddress) then exit;

    if IsHooking(pHookAddress) then exit;

    pHook:=FHookInfoCtrl.AddHookInfo(pHookAddress, pJumpBackAddress, fnCallBack);

    if pHook=nil then exit;
    result:= SetJumpCode(pHook);

    temp:='SetHook: ================= successfully ====='               +#13#10+
          'pHookAddress:$'      +inttohex(dword(pHook.Hook.pHookAddress),8)      +#13#10+
          'pJumpBackAddress:$'  +inttohex(dword(pHook.Hook.pJumpBackAddress),8)  +#13#10+
          'fnCallBack:$'        +inttohex(dword(pHook.Hook.fnCallBack),8);
    DebugView(temp);
    DbgViewAsHex(pchar(@pHook.szCodeBuffer[0]), CODE_BUFFER_SIZE);
    
end;

function THookCodePacket.FindBeHookedCodeHead(pHookRecord:PTHookRecord):pointer;
begin
  result:=@pHookRecord.szCodeBuffer[FdwBlockLength_Template];
end;

function THookCodePacket.UnHook(pHookAddress:pointer):boolean;
var
  pHookRecord:PTHookRecord;
  wLen:dword;
  pHookedCode:pointer;
begin
    result:=false;
    if pHookAddress=nil then exit;
    if not IsHooking(pHookAddress) then exit;
    pHookRecord:= FHookInfoCtrl.GetHookInfo(pHookAddress);
    wLen:=word(dword(pHookRecord.Hook.pJumpBackAddress)-dword(pHookRecord.Hook.pHookAddress));
    pHookedCode:=FindBeHookedCodeHead(pHookRecord);
    if not WriteMem(pHookRecord.Hook.pHookAddress, pHookedCode, wLen) then exit;

    DebugView('pHookedCode:$'+inttohex(dword(pHookedCode),8)+' wLen:'+inttostr(wLen));
    DbgViewAsHex(pHookedCode, wLen);

    result:= FHookInfoCtrl.DeleteHookInfo(pHookAddress);  

    DebugView('UnHook:$'+inttohex(dword(pHookAddress),8)+' successfully');
end;                                     

//=====================================================================

function THookInfoCtrl.AddHookInfo(pHookAddress     :pointer;
                                   pJumpBackAddress :pointer;
                                   fnCallBack       :pointer):PTHookRecord;
var
  HookRecord:THookRecord;
  wCount:word;
begin
  result:=nil;
  try
    zeromemory(@HookRecord, sizeof(THookRecord));
    HookRecord.Hook.pHookAddress:=pHookAddress;
    HookRecord.Hook.pJumpBackAddress:=pJumpBackAddress;
    HookRecord.Hook.fnCallBack:=fnCallBack;

    wCount:=FHookInfo.count;
    copymemory(@FHookInfo.Hooks[wCount], @HookRecord, sizeof(THookRecord));
    inc(FHookInfo.count);
    result:=@FHookInfo.Hooks[wCount];
    DebugView('AddHookInfo successflly! $'+inttoHex(dword(result),8));
  except
    DebugView('AddHookInfo Error! $'+inttoHex(dword(result),8));
  end;
end;

procedure THookInfoCtrl.DebugView(str:string);
begin
  if FDebugPrint then
    OutputDebugString(pchar(str));
end;

function THookInfoCtrl.DeleteHookInfo(pHookAddress:pointer):boolean;
var
  wCount:word;
  i,aim,len:integer;
  pTemp:pointer;
begin
    result:=false;
    if pHookAddress=nil then exit;
    wCount:= FHookInfo.count;
    aim:=-1;
    for i:=0 to wCount-1 do
    begin
        pTemp:= FHookInfo.Hooks[i].Hook.pHookAddress;
        if  pHookAddress=pTemp then
        begin
            aim:=i;
            break;
        end;
    end;
    
    if (aim=-1) or (aim>wCount-1) then exit;

    if not (aim=wCount-1) then
    begin
        len:=wCount-1-aim;
        copymemory(@FHookInfo.Hooks[aim], @FHookInfo.Hooks[aim+1], len*sizeof(THookRecord));
    end;

    dec(FHookInfo.count);

    ZeroMemory(@FHookInfo.Hooks[FHookInfo.count], SizeOf(THookRecord));

    result:=true;
end;

function THookInfoCtrl.GetHookInfo(pHookAddress:pointer):PTHookRecord;
var
  wCount:word;
  i,aim:integer;
begin
    result:=nil;
    if pHookAddress=nil then exit;
    wCount:= FHookInfo.count;
    aim:=-1;
    for i:=0 to wCount-1 do
    begin
        if  pHookAddress=FHookInfo.Hooks[i].Hook.pHookAddress then
        begin
            aim:=i;
            break;
        end;
    end;

    if aim=-1 then exit;

    result:=@FHookInfo.Hooks[aim];    
end;

procedure THookInfoCtrl.Clear;
begin
  ZeroMemory(@FHookInfo, sizeof(THookInfo));
end;

function THookInfoCtrl.GetHooksCount:word;
begin
    result:=FHookInfo.count;
end;


end.

