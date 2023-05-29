#include <sourcemod>
#include <tf2_stocks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"
#define MAX_ARENA_NAME 64
#define MAX_SPAWN_POINTS 15
#define MAX_ARENA_PLAYERS 4
#define MAXARENAS 63
#define MAXSPAWNS 15

enum GameplayType
{
  Gameplay_Unknown, 
  Gameplay_Ammomod, 
  Gameplay_Midair, 
  Gameplay_MGE, 
  Gameplay_BBall, 
  Gameplay_Ultiduo, 
  Gameplay_Turris, 
  Gameplay_KOTH, 
  Gameplay_Endif
}

enum ArenaStatus
{
  Arena_Fight, 
  Arena_Idle
}

enum struct SpawnPoint
{
  bool Valid;
  float OriginX;
  float OriginY;
  float OriginZ;
  float AngleX;
  float AngleY;
  float AngleZ;
}

enum struct Player
{
  char Name[MAX_NAME_LENGTH];
  int UserID;
  int ELO;
  int Score;
}

enum struct Arena
{
  char Name[MAX_ARENA_NAME];
  ArrayList Players;
  ArrayList PlayerQueue;
  ArrayList SpawnPoints;
  ArenaStatus Status;
  int FragLimit;
  int CapLimit;
  int MaxRating;
  int MinRating;
  int CountdownTime;
  ArrayList AllowedClasses;
  int AirshotHeight;
  int BoostVectors;
  float HPRatio;
  bool ShowHP;
  bool AllowChange;
  int EarlyLeave;
  bool VisibleHoop;
  bool InfiniteAmmo;
  bool AllowKOTH;
  float KOTHTimer;
  int KOTHTeamSpawn;
  int MinimumDistance;
  float RespawnTime;
  bool FourPlayers;
  bool Ultiduo;
  bool Turris;
  bool KOTH;
  GameplayType Gameplay;
}

ArrayList g_Arenas;
char g_Map[64];

public Plugin myinfo = 
{
  name = "[MGE] Core", 
  author = "ampere", 
  description = "MGEMod Core", 
  version = PLUGIN_VERSION, 
  url = "github.com/maxijabase"
};

public void OnPluginStart()
{
  LoadSpawnPoints();
  RegConsoleCmd("add", CMD_AddMenu, "Usage: add <arena number/arena name>. Add to an arena.");
  RegConsoleCmd("remove", CMD_Remove, "Remove from current arena.");
}

public void OnMapStart()
{
  HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_Post);
  HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
  FindConVar("mp_waitingforplayers_cancel").SetInt(1);
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
  TF2_RegeneratePlayer(GetClientOfUserId(event.GetInt("userid")));
}

void LoadSpawnPoints()
{
  g_Arenas = new ArrayList(sizeof(Arena));
  
  char txtFile[256];
  BuildPath(Path_SM, txtFile, sizeof(txtFile), "configs/mge_chillypunch_final4_fix2.mge.cfg");
  
  char currentSection[32];
  GetCurrentMap(g_Map, sizeof(g_Map));
  
  KeyValues kv = new KeyValues("SpawnConfigs");
  if (!kv.ImportFromFile(txtFile))
  {
    PrintToServer("Import unsuccessful! Aborting.");
    return;
  }
  
  kv.GotoFirstSubKey();
  
  do
  {
    // Create arena
    Arena arena;
    arena.AllowedClasses = new ArrayList(ByteCountToCells(32));
    arena.SpawnPoints = new ArrayList(sizeof(SpawnPoint));
    arena.Players = new ArrayList(ByteCountToCells(32));
    arena.PlayerQueue = new ArrayList(ByteCountToCells(32));
    arena.Status = Arena_Idle;
    
    // Get section name to get arena name
    kv.GetSectionName(currentSection, sizeof(currentSection));
    Format(arena.Name, sizeof(arena.Name), currentSection);
    
    // Jump to first key
    kv.GotoFirstSubKey();
    
    // Get section name again
    kv.GetSectionName(currentSection, sizeof(currentSection));
    
    // If this is the 'spawns' key, jump to it and get all spawn points of the arena
    if (StrEqual(currentSection, "spawns"))
    {
      int id;
      int spawnId = 1;
      char spawnIdStr[3];
      char spawnCoords[128];
      
      do
      {
        IntToString(spawnId, spawnIdStr, sizeof(spawnIdStr));
        kv.GetString(spawnIdStr, spawnCoords, sizeof(spawnCoords));
        
        SpawnPoint spawnPoint;
        spawnPoint = GetArenaSpawnPoints(spawnCoords);
        if (!spawnPoint.Valid)
        {
          SetFailState("Failed to parse spawn points for arena %s! Make sure to set them up properly.", arena.Name);
        }
        
        arena.SpawnPoints.PushArray(spawnPoint);
        spawnId++;
        IntToString(spawnId, spawnIdStr, sizeof(spawnIdStr));
      }
      while (kv.GetNameSymbol(spawnIdStr, id));
      
      kv.GoBack();
    }
    
    // Get optional parameters
    arena.FragLimit = kv.GetNum("fraglimit", 3);
    arena.CapLimit = kv.GetNum("caplimit", 3);
    arena.MinRating = kv.GetNum("minrating", -1);
    arena.MaxRating = kv.GetNum("maxrating", -1);
    arena.CountdownTime = kv.GetNum("cdtime", 3);
    arena.HPRatio = kv.GetFloat("hpratio", 1.5);
    arena.AirshotHeight = kv.GetNum("airshotheight", 250);
    arena.BoostVectors = kv.GetNum("boostvectors", 0);
    arena.VisibleHoop = kv.GetNum("vishoop", 0);
    arena.EarlyLeave = kv.GetNum("earlyleave", 0);
    arena.InfiniteAmmo = kv.GetNum("infammo", 1);
    arena.ShowHP = kv.GetNum("showhp", 1);
    arena.MinimumDistance = kv.GetFloat("mindist", 100.0);
    arena.FourPlayers = kv.GetNum("4player", 0);
    arena.AllowChange = kv.GetNum("allowchange", 0);
    arena.AllowKOTH = kv.GetNum("allowkoth", 0);
    arena.KOTHTeamSpawn = kv.GetNum("kothteamspawn", 0);
    arena.RespawnTime = kv.GetFloat("respawntime", 0.1);
    arena.KOTHTimer = kv.GetNum("timer", 180);
    
    // Get gameplay type
    char gameplayString[16];
    kv.GetString("gametype", gameplayString, sizeof(gameplayString));
    arena.Gameplay = GetArenaGameplayType(gameplayString);
    
    if (arena.Gameplay == Gameplay_Unknown)
    {
      SetFailState("Failed to parse gameplay type for arena %s! Make sure to set it to an accepted value.", arena.Name);
    }
    
    // Get arena allowed classes
    char classes[128];
    kv.GetString("classes", classes, sizeof(classes));
    arena.AllowedClasses = GetArenaAllowedClasses(classes);
    for (int i = 0; i < arena.AllowedClasses.Length; i++)
    {
      if (arena.AllowedClasses.Get(i) == TFClass_Unknown)
      {
        SetFailState("Failed to parse allowed classes for arena %s! Make sure to set them up properly.", arena.Name);
      }
    }
    
    // Push arena to global arenas array
    g_Arenas.PushArray(arena);
  }
  while (kv.GotoNextKey());
  
  delete kv;
  LogMessage("MGEMod Loaded with %d arenas.", g_Arenas.Length);
}

public void OnClientPostAdminCheck(int client)
{
  TF2_ChangeClientTeam(client, TFTeam_Spectator);
}

public Action CMD_AddMenu(int client, int args)
{
  char arg1[8];
  GetCmdArg(1, arg1, sizeof(arg1));
  
  int arenaIndex = StringToInt(arg1);
  
  if (arenaIndex > 0 && arenaIndex <= g_Arenas.Length)
  {
    AddToQueue(client, arenaIndex - 1);
    return Plugin_Handled;
  }
  
  ShowAddMenu(client);
  return Plugin_Handled;
}

void ShowAddMenu(int client)
{
  Menu menu = new Menu(Menu_Main);
  menu.SetTitle("Select an arena...");
  char item[32];
  char menuItemId[4];
  
  for (int i = 0; i < g_Arenas.Length; i++)
  {
    Arena arena;
    g_Arenas.GetArray(i, arena);
    Format(item, sizeof(item), "%s", arena.Name);
    
    IntToString(i, menuItemId, sizeof(menuItemId));
    menu.AddItem(menuItemId, item);
  }
  
  menu.Display(client, 20);
}

public int Menu_Main(Menu menu, MenuAction action, int param1, int param2)
{
  switch (action)
  {
    case MenuAction_Select:
    {
      int client = param1;
      char menuItemId[4];
      menu.GetItem(param2, menuItemId, sizeof(menuItemId));
      AddToQueue(client, StringToInt(menuItemId));
    }
  }
}

public Action CMD_Remove(int client, int args)
{
  RemoveFromQueue(client);
  return Plugin_Handled;
}

void AddToQueue(int client, int arenaid)
{
  Arena arena;
  g_Arenas.GetArray(arenaid, arena);
  
  switch (arena.Status)
  {
    case Arena_Idle:
    {
      arena.Players.Push(GetClientUserId(client));
      DataPack pack = new DataPack();
      pack.WriteCell(GetClientUserId(client));
      pack.WriteCell(arenaid);
      Debug("Frame in: %N AddToQueue", client);
      RequestFrame(Timer_ResetPlayer, pack);
    }
    case Arena_Fight:
    {
      arena.PlayerQueue.Push(GetClientUserId(client));
    }
  }
}

void RemoveFromQueue(int client)
{
  // Send player to spectator
  TF2_ChangeClientTeam(client, TFTeam_Spectator);
}

void Timer_ResetPlayer(DataPack pack)
{
  pack.Reset();
  int userid = pack.ReadCell();
  int arenaid = pack.ReadCell();
  delete pack;
  Debug("Frame out: %N AddToQueue", GetClientOfUserId(userid));
  
  Debug("Frame in: reset player %N", GetClientOfUserId(userid));
  ResetPlayer(GetClientOfUserId(userid), arenaid);
}

void ResetPlayer(int client, int arenaid)
{
  // Respawn the player
  TF2_ChangeClientTeam(client, TFTeam_Red);
  TF2_SetPlayerClass(client, TFClass_Scout);
  TF2_RespawnPlayer(client);
  
  Debug("Frame out: reset player %N", client);
  
  // Create teleport timer
  DataPack pack = new DataPack();
  pack.WriteCell(GetClientUserId(client));
  pack.WriteCell(arenaid);
  Debug("Frame in: teleport %N", client);
  RequestFrame(Timer_TeleportPlayer, pack);
}

void Timer_TeleportPlayer(DataPack pack)
{
  pack.Reset();
  int client = GetClientOfUserId(pack.ReadCell());
  int arenaid = pack.ReadCell();
  delete pack;
  
  Debug("Frame out: teleport %N", client);
  
  // Get arena
  Arena arena;
  g_Arenas.GetArray(arenaid, arena);
  
  // Pick a random spawn from that arena,
  SpawnPoint coords;
  arena.SpawnPoints.GetArray(GetRandomInt(0, arena.SpawnPoints.Length - 1), coords);
  
  // TODO: this fucking sucks
  float pointOrigin[3];
  pointOrigin[0] = coords.OriginX;
  pointOrigin[1] = coords.OriginY;
  pointOrigin[2] = coords.OriginZ;
  
  float pointAngles[3];
  pointAngles[0] = coords.AngleX;
  pointAngles[1] = coords.AngleY;
  pointAngles[2] = coords.AngleZ;
  
  float pointVelocity[3] = { 0.0, 0.0, 0.0 };
  
  // Teleport him to the designed spawn point
  TeleportEntity(client, pointOrigin, pointAngles, pointVelocity);
  
  // Emit respawn sound
  EmitAmbientSound("items/spawn_item.wav", pointOrigin, .delay = 1.0);
}
SpawnPoint GetArenaSpawnPoints(const char[] coords)
{
  SpawnPoint point;
  point.Valid = true;
  char spawn[6][16];
  int count = ExplodeString(coords, " ", spawn, sizeof(spawn), sizeof(spawn[]));
  
  point.OriginX = StringToFloat(spawn[0]);
  point.OriginY = StringToFloat(spawn[1]);
  point.OriginZ = StringToFloat(spawn[2]);
  
  if (count == 6)
  {
    point.AngleX = StringToFloat(spawn[3]);
    point.AngleY = StringToFloat(spawn[4]);
    point.AngleZ = StringToFloat(spawn[5]);
  }
  else if (count == 4)
  {
    point.AngleX = 0.0;
    point.AngleY = StringToFloat(spawn[3]);
    point.AngleZ = 0.0;
  }
  else
  {
    point.Valid = false;
  }
  
  return point;
}

GameplayType GetArenaGameplayType(const char[] gameplay)
{
  if (StrEqual(gameplay, "turris"))
    return Gameplay_Turris;
  if (StrEqual(gameplay, "koth"))
    return Gameplay_KOTH;
  if (StrEqual(gameplay, "ammomod"))
    return Gameplay_Ammomod;
  if (StrEqual(gameplay, "ultiduo"))
    return Gameplay_Ultiduo;
  if (StrEqual(gameplay, "bball"))
    return Gameplay_BBall;
  if (StrEqual(gameplay, "endif"))
    return Gameplay_Endif;
  if (StrEqual(gameplay, "midair"))
    return Gameplay_Midair;
  if (StrEqual(gameplay, "mge"))
    return Gameplay_MGE;
  
  return Gameplay_Unknown;
}

ArrayList GetArenaAllowedClasses(const char[] classes)
{
  ArrayList result = new ArrayList(ByteCountToCells(32));
  if (StrEqual(classes, "all") || classes[0] == '\0')
  {
    result.Push(TFClass_Scout);
    result.Push(TFClass_Sniper);
    result.Push(TFClass_Soldier);
    result.Push(TFClass_DemoMan);
    result.Push(TFClass_Medic);
    result.Push(TFClass_Heavy);
    result.Push(TFClass_Pyro);
    result.Push(TFClass_Spy);
    result.Push(TFClass_Engineer);
  }
  else
  {
    char class[9][9];
    int count = ExplodeString(classes, " ", class, sizeof(class), sizeof(class[]));
    
    for (int i = 0; i < count; i++)
    {
      TFClassType classType = TF2_GetClass(class[i]);
      result.Push(classType);
    }
  }
  
  return result;
}

void Debug(const char[] msg, any...)
{
  char out[1024];
  VFormat(out, sizeof(out), msg, 2);
  PrintToChatAll(out);
  PrintToServer(out);
} 