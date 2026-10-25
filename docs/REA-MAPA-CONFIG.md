# Mapa das configurações tirado do VMS antigo (REA + Hopper)

Gerado em 25/10/2026 lendo o binário do VMS antigo (`VMS` e `Frameworks/libnetsdk.dylib`, V2.2.1.1) com o REA/Hopper e
`otool`. Nada foi enviado às câmeras. Serve de referência para as telas do VMS Next: nomes exatos das capacidades,
valores das listas em texto e como cada tela do VMS antigo grava os campos.

## 1. Capacidades (`SystemFunction`, ABILITY_GET 1360)

O libnetsdk lê cada grupo de `SystemFunction` numa lista fixa de booleanos. O VMS antigo testa a posição (em hex) na
memória; por isso o código dele mostra, por exemplo, `+0xae` em vez de `SupportCorridorMode`. A tabela abaixo
liga as duas coisas.


**EncodeType**: `0x0` DoubleStream, `0x1` CombineStream, `0x2` SnapStream, `0x3` WaterMark, `0x4` IFrameRange, `0x5` LowBitRate, `0x6` SmartH264, `0x7` IntelligentEncode, `0x8` SmartH264Plus, `0x9` SmartH264V2, `0xa` CustomChnDAMode, `0xb` SmartEncodeDigital, `0xc` MultiChannel

**AlarmType**: `0xd` MotionDetect, `0xe` BlindDetect, `0xf` LossDetect, `0x10` AlarmConfig, `0x11` NetAlarm, `0x12` NetIpConflict, `0x13` NetAbort, `0x14` StorageNotExist, `0x15` StorageLowSpace, `0x16` StorageFailure, `0x17` VideoAnalyze, `0x18` NetAbortExtend, `0x19` IPCAlarm, `0x1a` Consumer433Alarm, `0x1b` ConsumerRemote, `0x1c` SerialAlarm, `0x1d` NewVideoAnalyze, `0x1e` PIRAlarm, `0x1f` BlurCheck, `0x20` 433Alarm, `0x21` PIRDetect, `0x22` HumanDection, `0x23` HumanDectionDVR, `0x24` HumanDectionNVR, `0x25` NewVideoAnalyze_digit, `0x26` HumanDectionNVRNew, `0x27` PEAInHumanPed, `0x28` FaceDetect, `0x29` HumanDVRSupportLevel, `0x2a` LightContrl

**NetServer**: `0x2b` NetIPFilter, `0x2c` NetDHCP, `0x2d` NetDDNS, `0x2e` NetEmail, `0x2f` NetMutliCast, `0x30` NetNTP, `0x31` NetPPPoE, `0x32` NetDNS, `0x33` NetARSP, `0x34` Net3G, `0x35` NetMobile, `0x36` NetUPNP, `0x37` NetFTP, `0x38` NetWifi, `0x39` NetAlarmCenter, `0x3a` NetPlatMega, `0x3b` NetPlatXingWang, `0x3c` NetPlatShiSou, `0x3d` NetPlatVVEye, `0x3e` NetRTSP, `0x3f` NetPhoneShortMsg, `0x40` NetPhoneMultimediaMsg, `0x41` NetDAS, `0x42` NetLocalSdkPlatform, `0x43` NetGodEyeAlarm, `0x44` NetNat, `0x45` NetVPN, `0x46` NetKeyboard, `0x47` NetSPVMN, `0x48` NetPMS, `0x49` NetKaiCong, `0x4a` MACProtocol, `0x4b` XMHeartBeat, `0x4c` MonitorPlatform, `0x4d` NetAnJuP2P, `0x4e` NetTUTKIOTC, `0x4f` NetBaiduCloud, `0x50` NetMobileWatch, `0x51` NetBjlThy, `0x52` NetOpenVPN, `0x53` NATProtocol, `0x54` PlatFormGBeyes, `0x55` NetGlobalEyes, `0x56` NetDataLink, `0x57` NetWifiMode, `0x58` NetIPv6, `0x59` NetPMSV2, `0x5a` Net4G, `0x5b` NetSPVMNSIP, `0x5c` RTMP, `0x5d` IPAdaptive, `0x5e` OnvifPwdCheckout, `0x5f` SerialTrans, `0x60` DualEthernet, `0x61` NetMidDAS, `0x62` NetEmailTLS, `0x63` NetGa1400

**PreviewType**: `0x64` Tour, `0x65` GUISet

**CommType**: `0x66` CommRS485, `0x67` CommRS232

**TipShow**: `0x69` NoBeepTipShow, `0x6a` NoFTPTipShow, `0x6b` NoEmailTipShow, `0x6c` NoDiskManagerButtonShow

**MobileDVR**: `0x6d` StatusExchange, `0x6e` DelaySet, `0x6f` CarPlateSet, `0x70` GpsTiming, `0x71` DVRBootType

**OtherFunction**: `0x72` DownLoadPause, `0x73` USBsupportRecord, `0x74` SDsupportRecord, `0x75` SupportOnvifClient, `0x76` SupportNetLocalSearch, `0x77` SupportMaxPlayback, `0x78` SupportNVR, `0x79` SupportC7Platform, `0x7a` SupportMailTest, `0x7b` SupportOSDInfo, `0x7c` HideDigital, `0x7d` NotSupportAH, `0x7e` NotSupportAV, `0x7f` SupportBT, `0x80` NotSupportTalk, `0x81` AlterDigitalName, `0x82` SupportShowConnectStatus, `0x83` SupportPlayBackExactSeek, `0x84` TitleAndStateUpload, `0x85` NOHDDRECORD, `0x86` MusicFilePlay, `0x87` SupportSetDigIP, `0x88` SupportShowProductType, `0x89` SupportCamareStyle, `0x8a` Supportonviftitle, `0x8b` SupportDimenCode, `0x8c` SupportStorageNAS, `0x8d` ShowFalseCheckTime, `0x8e` SupportTimeZone, `0x8f` ShowAlarmLevelRegion, `0x90` SupportPOS, `0x91` HddLowSpaceUseMB, `0x92` SupportCustomOemInfo, `0x93` SupportDigitalEncode, `0x94` SupportResumePtzState, `0x95` SupportSnapCfg, `0x96` SupportAbnormitySendMail, `0x97` SupportDigitalPre, `0x98` SupportWriteLog, `0x99` SuppportChangeOnvifPort, `0x9a` SupportCommDataUpload, `0x9b` SupportTextPassword, `0x9c` SupportCloudUpgrade, `0x9d` SupportUserProgram, `0x9e` SupportModifyFrontcfg, `0x9f` SupportFTPTest, `0xa0` SupportPtzIdleState, `0xa1` SupportImpRecord, `0xa2` SupportCameraMotorCtrl, `0xa3` SupportEncodeAddBeep, `0xa4` SupportFishEye, `0xa5` SupportSPVMNNasServer, `0xa6` SupportSmallChnTitleFont, `0xa7` SupportCfgCloudupgrade, `0xa8` SupportStorageFailReboot, `0xa9` SupportSplitControl, `0xaa` SupportRTSPClient, `0xab` SupportLowLuxMode, `0xac` SupportSwitchResolution, `0xad` SupportSlowMotion, `0xae` SupportCorridorMode, `0xaf` SupportWIFINVR, `0xb0` SupportSnapSchedule, `0xb1` SupportPWDSafety, `0xb2` SupportPlateDetect, `0xb3` SupportBreviary, `0xb4` SupportIntelligentPlayBack, `0xb5` SupportFaceDetect, `0xb6` SupportDeviceInfoNew, `0xb7` SupportBallCameraTrackDetect, `0xb8` SpecialNight, `0xb9` SupportSetHardwareAbility, `0xba` SupportSafetyEmail, `0xbb` SupportSensorAbilitySetting, `0xbc` SupportAlarmVoiceTips, `0xbd` SupportAlarmLinkLight, `0xbe` SupportSetRtcTime, `0xbf` SupportAudioFormat, `0xc0` SupportSoftPhotosensitive, `0xc1` SupportCloudUpgradeIPC, `0xc2` SupportFileUpgradeIPC, `0xc3` SupportParkingGuide, `0xc4` SupportLimitNetLoginUsers, `0xc5` SupportCoaxialParamCtrl, `0xc6` SupportShowH265X, `0xc7` SupportLogStorageCtrl, `0xc8` SupportAdminContactInfo, `0xc9` SupportWarnWeakPWD, `0xca` SupportStringChangedXPOE, `0xcb` SupportAlarmVoiceTipsType, `0xcc` SupportAcrossIPCTalk, `0xcd` SupportSetVolume, `0xce` SupportFaceDetectV2, `0xcf` SupportFaceksHumanDetect, `0xd0` SupportFacekshttpcommunication, `0xd1` SupportFaceRecognition, `0xd2` SupportCustomizeLpRect, `0xd3` NoSupportSafetyQuestion, `0xd4` SupportSysRemoteCtrl, `0xd5` SupportAlarmVoiceTipInterval, `0xd6` SupportSnapshotConfigV2, `0xd7` SupportEncodeLock, `0xd8` SupportHideNormalDLMode, `0xd9` SupportExtPlayBack, `0xda` SupportExportIPCLog, `0xdb` SupportShowIPCParam, `0xdc` SupportMultiTransData, `0xdd` SupportCustomLocalAlarmAudio, `0xde` SupportTargetDetect, `0xdf` SupportSmartAppFaceDetect, `0xe0` SupportSmartAppHumanDetect, `0xe1` SupportNetDetect, `0xe2` SupportSetInVolume, `0xe3` SupportAIBox, `0xe4` SupportRestoreConfigV2


## 2. Listas com valor em texto (o JSON grava o texto; o número é o interno do VMS antigo)

- **s_systemDebugMaps**: DebugCamera=0, DebugShell=1, DebugCameraSaveCmd=2
- **s_imgtypeMap**: typedefault=0, type1=1, type2=2
- **s_ptzLinkTypeMap**: None=0, Preset=1, Tour=2, Pattern=3
- **s_sensorTypeMap**: NC=0, NO=1
- **s_AlarmOutTypeMap**: AUTO=0, MANUAL=1, CLOSE=2
- **s_AlarmOutStatusMap**: OPEN=0, CLOSE=1
- **s_defaultConfigKeyMaps**: General=0, Encode=1, Record=2, NetService=3, NetCommon=4, Alarm=5, PtzComm=6, Account=7, Preview=8, CameraPARAM=9
- **s_deviceInfoKindMap**: SystemInfo=0, StorageInfo=1, WorkState=2, WifiAP=3, OEMInfo=4, GPSStatus=5, WifiStatus=6, 3GStatus=7, DASStatus=8, WifiNVRInfo=9, TutkVersion=10, LprVersion=11
- **s_eventTypeMaps**: LocalAlarm=1, NetAlarm=2, MotionDetect=4, LossDetect=5, BlindDetect=6, VideoSplit=8, VideoTour=9, VideoTitle=7, StorageFailure=11, StorageLowSpace=12, StorageNotExist=10, StorageReadError=15, StorageWriteError=16, NetAbort=13, NetIPConflict=17, ShutDown=22, Reboot=23, Upgrade=20, Backup=21, Comm=14, Emergency=18, DecConnect=19, ManualAlarm=3, NewFile=24, VideoAnalyze=25, IPCAlarm=26, SpeedAlarm=27, GSensorAlarm=28, LoginFailed=29, SerialAlarm=30, PIRAlarm=31, ConsSensorAlarm=32, WordDetect=33, BlurCheck=34, PlateDetect=35, FaceDetectV2=36, 433Alarm=37, PIRDetect=38, appEventHumanDetectAlarm=39, FaceDetect=40, FaceRecognition=41, CarShapeDetect=42
- **s_loginTypeMap**: GUI=0, Console=1, DVRIP-Web=2, DVRIP-SNS=3, DVRIP-Mobile=4, DVRIP-NetKeyboard=5, DVRIP-Server=6, DVRIP-AutoSearch=7, DVRIP-Upgrade=8, MegaEye=9, DVRIP-FutureHome=10, DVRIP-XmEye=11, DVRIP-Xm030=12, DVRIP-QunGuang=13
- **s_deviceTypeMap**: DVR=0, NVS=1, IPC=2, HVR=3, MVR=5, IVR=4
- **s_videoCompressionMap**: MPEG4=0, MPEG2=2, MPEG1=3, MJPG=5, H.263=4, H.264=7, H.265=8
- **s_videoResolutionMap**: D1=0, HD1=1, BCIF=2, CIF=3, QCIF=4, VGA=5, QVGA=6, SVCD=7, QQVGA=8, ND1=9, 650TVL=10, 720P=11, 1_3M=12, UXGA=13, 1080P=14, WUXGA=15, 2_5M=16, 3M=17, 5M=18, 1080N=19, 4M=20, 6M=21, 8M=22, 12M=23, 4K=24, 720N=25, WSVGA=26, NHD=27, 3M_N=28, 4M_N=29, 5M_N=30, 4K_N=31
- **s_videoBitrateControlMap**: CBR=0, VBR=1, MBR=2
- **s_combEncodeTransModeMap**: MultiReplay=1, NarrowBand=2
- **s_chanTypesMap**: Simulate=0, Digit=1
- **s_audioInFormatMaps**: G729_8KBIT=1, G726_16KBIT=2, G726_24KBIT=3, G726_32KBIT=4, G726_40KBIT=5, PCM_8TO16BIT=6, PCM_ALAW=7, PCM_ULAW=8, ADPCM8K16BIT=9, ADPCM16K16BIT=10, G711_ALAW=11, MPEG2_LAYER1=12, AMR8K16BIT=13, G711_ULAW=14, IMA_ADPCM_8K16BIT=15, AAC_8K16b=16, AAC_44100Hz=17
- **s_recordModeTypeMaps**: ClosedRecord=0, ManualRecord=1, ConfigRecord=2
- **s_snapModeTypeMaps**: ClosedSnap=0, ManualSnap=1, ConfigSnap=2
- **s_AudioModeTypeMaps**: Single=0, Double=1
- **s_encStaticParamMaps**: baseline=0, mainprofile=1, highprofile=2
- **s_DigTimeSynMaps**: OFF=0, UTC=1, Local=2, T&Z=3
- **s_encodeStreamTypeMap**: MainStream=0, ExtraStream2=1, ExtraStream3=2, ExtraStream4=3, JPEGStream=4
- **s_GPSStatusTypeMap**: Success=0, NoSignal=1, NoData=2, Invalid=3, On=0, Off=1, NoDevice=2, Invalid=9
- **s_monitorActionMap**: Start=0, Stop=1, Claim=2, Pause=3, Continue=4, Request=5
- **s_monitorStreamTypeMap**: Main=0, Extra1=1, Sub=1, Extra=1, Third=2, Fourth=3, Jpeg=4
- **s_monitorTransTypeMap**: TCP=0, UDP=1, MCAST=2, RTP=3
- **s_combinTypeMap**: COMBIN_1=1, COMBIN_2=2, COMBIN_3=3, COMBIN_4=4, COMBIN_5=5, COMBIN_6=6, COMBIN_7=7, COMBIN_8=8, COMBIN_9=9, COMBIN_10=10, COMBIN_11=11, COMBIN_12=12, COMBIN_13=13, COMBIN_14=14, COMBIN_15=15, COMBIN_16=16, COMBIN_1_4=17, COMBIN_5_8=18, COMBIN_9_12=19, COMBIN_13_16=20, COMBIN_1_8=21, COMBIN_9_16=22, COMBIN_1_9=23, COMBIN_8_16=24, COMBIN_1_16=25, CONNECT_ALL=255, NONE=0
- **s_machineActionMap**: Reboot=0, ShutDown=1
- **s_talkControlTypesMap**: Start=0, Stop=1, Claim=2, Request=3, PauseUpload=4, ResumeUpload=5, AcrossStart=6, AcrossStop=7
- **s_upgradeActionMap**: Start=0, Abort=1
- **s_upgradeTypesMap**: System=0, Module=1
- **s_logSearchKindMap**: LogAll=0, LogSystem=1, LogConfig=2, LogStorage=3, LogAlarm=4, LogRecord=5, LogAccount=6, LogFile=7
- **s_logControlActionMaps**: RemoveAll=0, LogOn=1, LogOff=2, LogOnlyInMemory=3
- **s_storageControlTypeMaps**: SetType=0, Recover=1, Partition=2, Clear=3
- **s_storageControlTypeMaps22**: ReadWrite=0, ReadOnly=1, Events=2, Redundant=3, SnapShot=4
- **s_storageControlTypeMaps33**: Data=0, Partition=1
- **s_ptzControlSetPatternStatusMaps**: SetBegin=0, SetEnd=1, Start=2, Stop=3, clear=4
- **s_eventTypeMap**: VideoMotion=4, VideoBlind=6, VideoLoss=5, LocalIO=1, NetAlarm=2, CommAlarm=14, NetAbort=13, StorageNotExist=10, StorrageLowSpace=12, StorageFailure=11, ManualAlarm=3, VideoTitle=7, VideoSplit=8, VideoTour=9, NetAbort=13, CommAlarm=14, StorageFailureRead=15, StorageFailureWrite=16, NetIPConflict=17, VideoAnalyze=25, IPCAlarm=26, LoginFailed=29, SerialAlarm=30, PIRAlarm=31, ConsSensorAlarm=32, WordDetect=33, BlurCheck=34, PlateDetect=35, FaceDetectV2=36, 433Alarm=37, PIRDetect=38, appEventHumanDetectAlarm=39, FaceDetect=40, FaceRecognition=41, CarShapeDetect=42
- **s_eventStatusMap**: Start=0, Stop=1, Pulse=4
- **s_kbStatusMap**: KeyDown=0, KeyUp=1
- **s_tcommTypeMap**: RS232=0, RS485=1
- **s_tcommOprMap**: Start=0, Stop=1
- **s_NatStatusTypeMap**: DisEnable=0, Probing=1, Connecting=2, Conneted=3
- **s_FileControlTypeMap**: FileDelet=0, RemoveDirectory=1, RemoveAll=2, RunTimeClear=3
- **s_DecChnStateTypeMap**: None=0, NoConfig=1, NoLogin=2, NoConnect=3, Conneted=4, LoginFailed=5, Offline=6
- **s_netStreamTypeMap**: TCP=0, UDP=1, MCAST=2, NAT=3, DaHua=4, RTSP=5, IPV6=6
- **s_netTransferPlanMap**: AutoAdapt=0, Quality=1, Fluency=2, Transmission=3
- **s_DigManagerShowMap**: ShowNone=0, ShowAll=1
- **s_netProtocolTypeMap**: TCP=0, UDP=1, MCAST=2, NAT=3, DaHua=4, RTSP=5, IPV6=6
- **s_consunmerProCmdMap**: StartAddDev=0, StopAddDev=1, DeleteDev=2, ChangeDevName=3, InquiryStatus=4, GetAllDevList=5, ChangeDevStatus=6, GetDevListStatus=7, ChangeMode=8, GetModeConfig=9, GetAllModeList=10, ChangeModeName=11, GetLinkState=12

## 3. Tela por tela: como o VMS antigo lê e grava

Valores confirmados nas funções `onUpdateConfig` / `onSaveConfig` de cada tela e nas tabelas `exchangeTable<…>` do
libnetsdk. ✅ = o VMS Next já fazia igual; 🔧 = corrigido nesta revisão; ⚠️ = diferença ainda em aberto.

### Parâmetros da câmera (`Camera.Param` / `Camera.ParamEx`, tela CCameraParamConfig)
| Campo JSON | Controle no VMS antigo | Valor gravado |
|---|---|---|
| `WhiteBalance` | Auto / Indoor / Outdoor | posição 0–2 ✅ |
| `DayNightColor` | Star IR, Full Color, BlackAndWhiteMode, IntellMotionDetect, WarmLight, IntelligentInfrared, LicensePlateMode | 0–6. 0–2 somem com `SupportHideNormalDLMode`; 6 só com `SupportPlateDetect` 🔧 |
| `ElecLevel` | número 0–100 | ✅ |
| `ApertureMode`, `BLCMode`, `PictureFlip`, `PictureMirror`, `RejectFlicker`, `IrcutSwap` | OFF/ON | 0/1 ✅ |
| `ExposureParam.Level` | Auto + "Manual 1/N" | 0 = auto; N = posição nos `Speeds` da capacidade **ordenados do maior para o menor** 🔧 |
| `ExposureParam.LeastTime` / `MostTime` | ms com 3 casas | µs, de 100 a 80000, só gravados no modo automático 🔧 |
| `GainParam.Gain` / `AutoGain` | número / OFF-ON | ✅ |
| `EsShutter` (obturador lento) | None / Low / Middle / Strong | **posição × 2** = 0/2/4/6 ✅ |
| `IRCUTMode` | SyncSwitch / AutoSwitch | 0/1 ✅ |
| `DncThr` | controle deslizante | **10 a 50** (o VMS Next ia de 0 a 100) 🔧 |
| `AeSensitivity` | controle deslizante | 1 a 10 ✅ |
| `Day_nfLevel` / `Night_nfLevel` | 0–5 | ✅ |
| `ParamEx.BroadTrends.Gain` / `AutoGain` | número / OFF-ON | ✅ |
| `ParamEx.Style` | Style1/2/3 | `typedefault`/`type1`/`type2` ✅ |
| `ParamEx.CorridorMode` | NormalMode, CorridorMode1, Reflection, CorridorMode2 | 0–3, só com `OtherFunction.SupportCorridorMode` 🔧 (novo) |
| `ParamEx.PreventOverExpo` | OFF/ON | só com `Camera.SupportPreventOverExpo` 🔧 |
| `ParamEx.AutomaticAdjustment` | controle deslizante | só nos modos de luz dupla ✅ |
| `ParamEx.LDCValue` | controle deslizante `MinLDC`…`MaxLDC` | só com `Camera.SupportSetLDC` 🔧 (novo, faixa fixa 0–100) |
| `Camera.ClearFog` `enable` / `level` | OFF-ON / número | ✅ |

Capacidade `Camera` (libnetsdk `CameraAbility`): `Count`, `Speeds`, `Status`, `ElecLevel`, `Luminance`, `Version`,
`IsFishLens`, `SupportIntellDoubleLight`, `SupportPreventOverExpo`, `SupportSetLDC`, `MinLDC`, `MaxLDC`.

### Luz branca (`Camera.WhiteLight`, tela CCameraWhiteLightWidget)
- Câmera de luz dupla: lista "Day/Night Mode" com **Auto / Intelligent / Close** (iguais ao VMS Next) ✅.
- Outras: "Work Mode" com KeepOpen, Auto, Timing, Intelligent, Atmosphere, Glint, Close.
- `MoveTrigLight.Duration`: **0 a 120 s** na luz dupla, 0 a 60 s nas outras (o VMS Next oferecia 180 e 300 s) 🔧.
- `MoveTrigLight.Level`: Low/Middle/High = 1/3/5 só no modo Intelligent; nos outros, níveis 1 a 5 🔧.
- Horário (modo Timing): hora e minuto de início e fim. O VMS antigo **não tem** controle de brilho; o do VMS Next vem do iCSee.

### Qualidade do vídeo (`Simplify.Encode`, tela CEncodeMediaConfig)
- `Quality`: Worst, Worse, General, Good, Better, Best = 1–6 ✅. `GOP` = posição + 1 ✅. `BitRate` = número da lista ✅.
- `BitRateControl`: CBR=0, VBR=1, MBR=2 (texto no JSON). `Compression`: H.264, H.265 (texto).
- Codificação inteligente: Close / H265+ (`SmartH264` = true) / H265AI ou H265++ (`SmartH264Plus` = 1). Com H.264: Close / H264+ / H265x.
  ⚠️ O VMS Next só oferece Fechar e H265AI; falta descobrir em qual configuração fica o `SmartH264` "H265+".
- Perfil estático: o VMS antigo monta a lista conforme a capacidade (`baseline`, `main profile`, `high profile`) e grava
  a **posição** na lista. No libnetsdk, o `AVEnc.EncodeStaticParamV2` usa baseline=0, mainprofile=1, highprofile=2;
  o `AVEnc.EncodeStaticParam` (usado pelo VMS Next, 1/2/3) passa o número sem converter. ⚠️ Conferir no Diagnóstico.

### Detecção (`Detect.MotionDetect` e parecidas, tela CVDMotionDetect)
- `Level` = posição + 1 (6 níveis) ✅.
- `EventHandler.RecordLatch` ("Record Delay"): o VMS antigo recusa menos de 10 e mais de 300 s 🔧.
- `EventHandler.PtzLink`: tipo (None=0, Preset=1, Tour=2, Pattern=3) e número por canal ✅.
- Saída de alarme + atraso: o VMS antigo recusa atraso acima de 3000.

### Saída de alarme (`Alarm.AlarmOut`, tela CAlarmOutputConfig)
- `AlarmOutType`: AUTO=0 (Schedule), MANUAL=1, CLOSE=2; `AlarmOutStatus`: OPEN/CLOSE ✅.

### Gravação e Foto (`Record`, `Snapshot`)
- `RecordMode`: ClosedRecord / ManualRecord / ConfigRecord; `SnapMode`: ClosedSnap / ManualSnap / ConfigSnap.
- Campos: `PreRecord`, `Redundancy`, `PacketLength`, `TimeSection`, `Mask` (igual à Foto, com `PreSnap`).

### Sistema e horário
- Fuso: `System.TimeZone.timeMin` (minutos a oeste de UTC) e `FirstUserTimeZone` 🔧.
- `NetWork.NetNTP.TimeZone`: 13 = servidor escolhido (Custom), 14 = Auto Select Server 🔧.
