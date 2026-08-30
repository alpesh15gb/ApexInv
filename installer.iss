[Setup]
AppName=Apex Books
AppVersion=1.0.0
DefaultDirName={pf}\ApexBooks
DefaultGroupName=Apex Books
OutputDir=Output
OutputBaseFilename=ApexBooksSetup
Compression=lzma
SolidCompression=yes

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs

[Icons]
Name: "{group}\Apex Books"; Filename: "{app}\ApexBooks.exe"
Name: "{commondesktop}\Apex Books"; Filename: "{app}\ApexBooks.exe"
