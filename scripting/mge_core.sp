#define DEBUG 1

#include <sourcemod>
#include <tf2_stocks>
#include <sdkhooks>

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
  int Index;
  int UserID;
  int ELO;
  int Score;
  int ArenaId;
  float Handicap;
  
  void Fill(int client)
  {
    GetClientName(client, this.Name, sizeof(this.Name));
    this.UserID = GetClientUserId(client);
  }
  
  Arena GetArena()
  {
    Arena arena;
    arena = GetArena(this.ArenaId);
    return arena;
  }
  
  void CloseAddMenu()
  {
    int client = GetClientOfUserId(this.UserID);
    if (GetClientMenu(client, null) != MenuSource_None)
    {
      InternalShowMenu(client, "\10", 1); // thanks to Zira
      CancelClientMenu(client, true, null);
    }
  }
}

enum struct Arena
{
  char Name[MAX_ARENA_NAME];
  int Id;
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
  
  SpawnPoint GetRandomSpawn()
  {
    SpawnPoint coords;
    this.SpawnPoints.GetArray(GetRandomInt(0, this.SpawnPoints.Length - 1), coords);
    return coords;
  }
  
  void AddPlayer(Player player)
  {
    this.Players.PushArray(player);
  }
  
  void RemovePlayer(Player player)
  {
    Player arenaPlayer;
    for (int i = 0; i < this.Players.Length; i++)
    {
      this.Players.GetArray(i, arenaPlayer);
      if (arenaPlayer.UserID == player.UserID)
      {
        this.Players.Erase(i);
      }
    }
  }
}

ArrayList g_Arenas;
ArrayList g_Players;
char g_Map[64];
bool g_Late;

public Plugin myinfo = 
{
  name = "[MGE] Core", 
  author = "ampere", 
  description = "MGEMod Core", 
  version = PLUGIN_VERSION, 
  url = "github.com/maxijabase"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  EngineVersion version = GetEngineVersion();
  if (version != Engine_TF2)
  {
    SetFailState("This plugin was made for use with Team Fortress 2 only.");
  }
  
  g_Late = late;
  
  return APLRes_Success;
}

public void OnPluginStart()
{
  //ServerCommand("sm plugins unload mge_core");
  LoadSpawnPoints();
  RegConsoleCmd("jointeam", CMD_JoinTeam);
  RegConsoleCmd("autoteam", CMD_AutoTeam);
  RegConsoleCmd("add", CMD_Add, "Usage: add <arena number/arena name>. Add to an arena.");
  RegConsoleCmd("remove", CMD_Remove, "Remove from current arena.");
  RegConsoleCmd("debugplayers", CMD_DebugPlayers);
  RegConsoleCmd("debugarenas", CMD_DebugArenas);
  RegConsoleCmd("kill", CMD_Kill);
  
  g_Players = new ArrayList(sizeof(Player));
  
  if (g_Late)
  {
    for (int i = 1; i <= MaxClients; i++)
    {
      if (IsValidClient(i))
      {
        ForcePlayerSuicide(i);
        OnClientPostAdminCheck(i);
      }
    }
  }
}

public Action CMD_Kill(int client, int args)
{
  SDKHooks_TakeDamage(client, 0, 0, 300.0);
  return Plugin_Handled;
}

public Action CMD_DebugPlayers(int client, int args)
{
  
  if (g_Players.Length == 0) {
    Debug("No players.");
    return Plugin_Handled;
  }
  
  for (int i = 0; i < g_Players.Length; i++)
  {
    Player player;
    g_Players.GetArray(i, player);
    Debug("=====TICK %2.f====", GetTickedTime());
    Debug("%d - Name: %s", i, player.Name);
    Debug("%d - UserID: %d", i, player.UserID);
    Debug("%d - ArenaID: %d", i, player.ArenaId);
    Debug("==================");
  }
  return Plugin_Handled;
}

public Action CMD_DebugArenas(int client, int args)
{
  bool full = args > 0;
  for (int i = 0; i < g_Arenas.Length; i++)
  {
    Arena arena;
    g_Arenas.GetArray(i, arena);
    Debug("");
    Debug("=====TICK %2.f====", GetTickedTime());
    Debug("%d - Arena: %s (%d)", i, arena.Name, arena.Id);
    Debug("%d - Status: %d", i, arena.Status);
    Debug("%d - Players:", i);
    if (arena.Players.Length == 0)
    {
      Debug("No players on arena %d", i);
    }
    for (int j = 0; j < arena.Players.Length; j++)
    {
      Player player;
      g_Players.GetArray(j, player);
      Debug("   - Player %d - Name: %s", j, player.Name);
      Debug("   - Player %d - UserID: %d", j, player.UserID);
      Debug("   - Player %d - ArenaID: %d", j, player.ArenaId);
    }
    if (full)
    {
      Debug("%d - Spawnpoints:", i);
      for (int k = 0; k < arena.SpawnPoints.Length; k++)
      {
        SpawnPoint point;
        arena.SpawnPoints.GetArray(k, point);
        Debug("  - %d, %d, %d", point.OriginX, point.OriginY, point.OriginZ);
      }
    }
    Debug("");
  }
  return Plugin_Handled;
}

public void OnMapStart()
{
  HookEvent("teamplay_round_start", Event_OnRoundStart, EventHookMode_Post);
  HookEvent("player_death", Event_OnPlayerDeath, EventHookMode_Pre);
  HookEvent("player_spawn", Event_OnPlayerSpawn, EventHookMode_Post);
  HookEvent("player_hurt", Event_OnPlayerHurt, EventHookMode_Pre);
  HookEvent("player_team", Event_OnPlayerJoinTeam, EventHookMode_Pre);
  HookEvent("teamplay_win_panel", Event_OnWinPanelDisplay, EventHookMode_Post);
  
  FindConVar("mp_autoteambalance").SetInt(1);
  FindConVar("mp_teams_unbalance_limit").SetInt(32);
  FindConVar("mp_tournament").SetInt(0);
}

public Action Event_OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
  FindConVar("mp_waitingforplayers_cancel").SetInt(1);
  return Plugin_Continue;
}

public Action Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
  int userid = event.GetInt("userid");
  Player player;
  player = GetPlayer(userid);
  DataPack pack = new DataPack();
  pack.WriteCellArray(player, sizeof(player));
  CreateTimer(0.1, Timer_ResetPlayer, pack);
  
  /*
    - Skip death ringer deaths
    - Increase killer score
    - Calculate ELO if match is over
    - Process next match if queue is not empty
  */
}

public Action Event_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
  /*
    - Set player HP (take HP ratio in account)
    - Restore ammo count
    - 
  */
}

public Action Event_OnPlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
  /*
    - ENDIF calculations idk
    - Expose to forwards for logging
  */
}

public Action Event_OnPlayerJoinTeam(Event event, const char[] name, bool dontBroadcast)
{
  /*
    - If player joins spec, remove him from queue
    - Prevent team switch altogether?
    - ^ update: dont do this here! hook jointeam command for better UX
  */
  
  
  
}

public Action Event_OnWinPanelDisplay(Event event, const char[] name, bool dontBroadcast)
{
  /*
    - Disable stats so people leaving at the end of the map don't lose points.
  */
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
  
  int arenaId = 1;
  
  do
  {
    // Create arena
    Arena arena;
    arena.Id = arenaId++;
    arena.AllowedClasses = new ArrayList(ByteCountToCells(32));
    arena.SpawnPoints = new ArrayList(sizeof(SpawnPoint));
    arena.Players = new ArrayList(sizeof(Player));
    arena.PlayerQueue = new ArrayList(sizeof(Player));
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
  Player player;
  player.Fill(client);
  g_Players.PushArray(player);
  
  Debug("Player %s with userid %d was pushed.", player.Name, player.UserID);
  
  TF2_ChangeClientTeam(client, TFTeam_Spectator);
}

public void OnClientDisconnect(int client)
{
  int userid = GetClientUserId(client);
  Player player;
  player = GetPlayer(userid);
  g_Players.Erase(player.Index);
}

public Action CMD_Add(int client, int args)
{
  char arg1[8];
  GetCmdArg(1, arg1, sizeof(arg1));
  
  int arenaId = StringToInt(arg1);
  
  if (arenaId > 0 && arenaId <= g_Arenas.Length)
  {
    AddToQueue(client, arenaId);
    
    // Debug
    Debug("[CMD_Add] Player chose arena %d", arenaId);
    Arena arena;
    arena = GetArena(arenaId);
    Debug("[CMD_Add] This is arena %s", arena.Name);
    
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
  
  // i starts at 0 because I need to access all array elements
  for (int i = 0; i < g_Arenas.Length; i++)
  {
    Arena arena;
    g_Arenas.GetArray(i, arena);
    Format(item, sizeof(item), "%s", arena.Name);
    
    // assign i + 1 to item ID so it corresponds to arena ID
    IntToString(i + 1, menuItemId, sizeof(menuItemId));
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
  
  return 0;
}

public Action CMD_Remove(int client, int args)
{
  RemoveFromQueue(client);
  return Plugin_Handled;
}

public Action CMD_JoinTeam(int client, int args)
{
  // We will block manual team joining, but show add menu if they're on spec
  char team[16];
  GetCmdArg(1, team, sizeof(team));
  
  if (!strcmp(team, "spectate"))
  {
    RemoveFromQueue(client);
    Debug("Removing from queue...");
    return Plugin_Continue;
  }
  else {
    Debug("Can't switch teams!");
    if (TF2_GetClientTeam(client) == TFTeam_Spectator)
    {
      ShowAddMenu(client);
    }
    return Plugin_Stop;
  }
}

public Action CMD_AutoTeam(int client, int args)
{
  // We will block autoteam command usage, and show add menu instead
  Debug("Preventing autoteam...");
  if (TF2_GetClientTeam(client) == TFTeam_Spectator)
  {
    ShowAddMenu(client);
  }
  return Plugin_Stop;
}

void AddToQueue(int client, int arenaid)
{
  // Get player
  Player player;
  player = GetPlayer(GetClientUserId(client));
  
  // Ignore if trying to add to the arena he's already at
  if (player.ArenaId == arenaid)
  {
    return;
  }
  
  // Remove from previous arena
  if (player.ArenaId != 0)
  {
    Arena playerArena;
    playerArena = player.GetArena();
    playerArena.RemovePlayer(player);
  }
  
  // Get destination arena
  Arena arena;
  arena = GetArena(arenaid);
  
  switch (arena.Status)
  {
    case Arena_Idle:
    {
      // Set player's new arena
      g_Players.Set(player.Index, arenaid, Player::ArenaId);
      player.ArenaId = arenaid;
      Debug("[AddToQueue] Adding %s (index %d) to arena %d", player.Name, player.Index, arenaid);
      Debug("[AddToQueue] player %s's arena is now ID %d (should be %d)", player.Name, player.ArenaId, arenaid);
      
      // Push player to arena
      arena.AddPlayer(player);
      
      // Reset player
      DataPack pack = new DataPack();
      pack.WriteCellArray(player, sizeof(player));
      CreateTimer(0.1, Timer_ResetPlayer, pack);
    }
    case Arena_Fight:
    {
      arena.PlayerQueue.Push(GetClientUserId(client));
    }
  }
  
  // Close client's menu
  player.CloseAddMenu();
}

void RemoveFromQueue(int client)
{
  // Send player to spectator
  TF2_ChangeClientTeam(client, TFTeam_Spectator);
  
  // Delete his arena ID
  Player player;
  player = GetPlayer(GetClientUserId(client));
  
  g_Players.Set(player.Index, 0, Player::ArenaId);
  
  // Delete player from arena player list
  Arena arena;
  arena = player.GetArena();
  arena.RemovePlayer(player);
}

Action Timer_ResetPlayer(Handle timer, DataPack pack)
{
  pack.Reset();
  Player player;
  pack.ReadCellArray(player, sizeof(player));
  delete pack;
  
  Debug("[Timer_ResetPlayer] Resetting player %s who died in arena %d", player.Name, player.ArenaId);
  
  ResetPlayer(player);
  
  return Plugin_Handled;
}

void ResetPlayer(Player player)
{
  int client = GetClientOfUserId(player.UserID);
  
  // Respawn the player
  TF2_ChangeClientTeam(client, TFTeam_Red);
  TF2_SetPlayerClass(client, TFClass_Scout);
  TF2_RespawnPlayer(client);
  
  // Create teleport timer
  DataPack pack = new DataPack();
  pack.WriteCellArray(player, sizeof(player));
  
  CreateTimer(0.1, Timer_TeleportPlayer, pack);
}

Action Timer_TeleportPlayer(Handle timer, DataPack pack)
{
  pack.Reset();
  Player player;
  pack.ReadCellArray(player, sizeof(player));
  delete pack;
  
  int client = GetClientOfUserId(player.UserID);
  
  // Get arena
  Arena arena;
  arena = player.GetArena();
  Debug("[Timer_TeleportPlayer] Getting arena %s (id %d)", arena.Name, player.ArenaId);
  
  // Pick a random spawn from that arena,
  SpawnPoint coords;
  coords = arena.GetRandomSpawn();
  
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
  EmitAmbientSound("items/spawn_item.wav", pointOrigin);
  
  return Plugin_Handled;
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

// Use this to get a player from the global players array based on userid
Player GetPlayer(int userid)
{
  Player player;
  
  Debug("[GetPlayer] total player count is %d", g_Players.Length);
  for (int i = 0; i < g_Players.Length; i++)
  {
    g_Players.GetArray(i, player);
    Debug("[GetPlayer] searching through player %d: %s...", i, player.Name);
    if (player.UserID == userid)
    {
      Debug("[GetPlayer] found player %s with arenaid %d", player.Name, player.ArenaId);
      player.Index = i;
      return player;
    }
  }
  
  if (player.UserID == 0)
  {
    Debug("[GetPlayer] userid was 0!!!");
  }
  
  return player;
}

Arena GetArena(int arenaId)
{
  Arena arena;
  for (int i = 0; i < g_Arenas.Length; i++)
  {
    g_Arenas.GetArray(i, arena);
    if (arena.Id == arenaId)
    {
      return arena;
    }
  }
}

void Debug(const char[] msg, any...)
{
  #if DEBUG == 1
  char out[1024];
  VFormat(out, sizeof(out), msg, 2);
  PrintToChatAll(out);
  PrintToServer(out);
  #endif
}

bool IsValidClient(int iClient, bool bIgnoreKickQueue = false)
{
  if 
    (
    // "client" is 0 (console) or lower - nope!
    0 >= iClient
    // "client" is higher than MaxClients - nope!
     || MaxClients < iClient
    // "client" isnt in game aka their entity hasn't been created - nope!
     || !IsClientInGame(iClient)
    // "client" is in the kick queue - nope!
     || (IsClientInKickQueue(iClient) && !bIgnoreKickQueue)
    // "client" is sourcetv - nope!
     || IsClientSourceTV(iClient)
    // "client" is the replay bot - nope!
     || IsClientReplay(iClient)
    )
  {
    return false;
  }
  return true;
} 