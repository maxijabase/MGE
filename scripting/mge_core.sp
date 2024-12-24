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

#define AN_THREE "vo/announcer_begins_3sec.mp3"
#define AN_TWO "vo/announcer_begins_2sec.mp3"
#define AN_ONE "vo/announcer_begins_1sec.mp3"
#define AN_FIGHT "vo/announcer_am_roundstart04.mp3"

ArrayList g_Arenas;
ArrayList g_Players;
char g_Map[64];
bool g_Late;
Handle hud_ArenaInfo;

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
  Arena_Countdown, 
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
  int ArenaId;
  float Handicap;
  bool ShowHUD;
  bool BotRequested;
  TFClassType BotClass;
  
  void Fill(int client)
  {
    GetClientName(client, this.Name, sizeof(this.Name));
    this.UserID = GetClientUserId(client);
    this.BotRequested = false;
    this.BotClass = TFClass_Unknown;
    this.Index = g_Players.Length;
  }

  void SetClass(TFClassType class)
  {
    int client = this.ToClient();
    if (!IsValidClient(client))
    {
      return;
    }
    TF2_SetPlayerClass(client, class);
  }
  
  void Reset()
  {
    int client = this.ToClient();
    
    if (!IsValidClient(client))
    {
      return;
    }

    // Get current class before team change  
    TFClassType currentClass = TF2_GetPlayerClass(client);
    
    // Get arena
    Arena arena;
    arena = this.GetArena();
    
    if (IsFakeClient(client)) {
      // For bots, find the player who requested them
      Player requester;
      for (int i = 0; i < g_Players.Length; i++) {
        g_Players.GetArray(i, requester);
        if (requester.BotRequested) {
          // Found the requester - set bot's class to requester's chosen bot class
          TFClassType requestedClass = requester.BotClass;
          if (requestedClass != TFClass_Unknown) {
            this.SetClass(requestedClass);
            currentClass = requestedClass; // Update currentClass to match
          }
          break;
        }
      }
    } else {
      // Original class validation for human players
      if (currentClass == TFClass_Unknown || !arena.IsClassAllowed(currentClass)) {
        currentClass = view_as<TFClassType>(arena.AllowedClasses.Get(0));
        this.SetClass(currentClass);
      }
    }
    
    // Cancel ongoing taunts
    if (TF2_IsPlayerInCondition(client, TFCond_Taunting))
    {
      TF2_RemoveCondition(client, TFCond_Taunting);
    }
    
    // Respawn or regenerate
    if (!IsPlayerAlive(client))
    {
      if (currentClass != TF2_GetPlayerClass(client))
      {
        this.SetClass(currentClass);
      }
      TF2_RespawnPlayer(client);
    } else
    {
      TF2_RegeneratePlayer(client);
      ExtinguishEntity(client);
    }
    
    // Create teleport timer
    DataPack pack = new DataPack();
    pack.WriteCellArray(this, sizeof(this));
    CreateTimer(0.1, Timer_TeleportPlayer, pack);
  }

  Arena GetArena()
  {
    return GetArena(this.ArenaId);
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
  
  Player GetOpponent()
  {
    Player opponent;
    
    // Check if player is in a valid arena
    if (this.ArenaId == 0) {
      return opponent;
    }
    
    // Get player's arena
    Arena arena;
    arena = this.GetArena();
    
    // Check if arena has enough players for an opponent
    if (arena.Players.Length < 2) {
      return opponent;
    }
    
    // Find this player's index in arena players array
    for (int i = 0; i < arena.Players.Length; i++) {
      Player arenaPlayer;
      arena.Players.GetArray(i, arenaPlayer);
      
      if (arenaPlayer.UserID == this.UserID) {
        // Found self - get opponent based on odd/even position
        int opponentIndex = (i % 2 == 0) ? i + 1 : i - 1;
        
        if (opponentIndex < arena.Players.Length) {
          arena.Players.GetArray(opponentIndex, opponent);
          return opponent;
        }
      }
    }
    
    return opponent;
  }

  void DestroyBuildings()
  {
    int building = -1;
    while ((building = FindEntityByClassname(building, "obj_*")) != -1)
    {
      if (GetEntPropEnt(building, Prop_Send, "m_hBuilder") == GetClientOfUserId(this.UserID))
      {
          SetVariantInt(9999);
          AcceptEntityInput(building, "RemoveHealth");
      }
    }
  }

  int ToClient()
  {
    return GetClientOfUserId(this.UserID);
  }

  void ShowPlayerHud()
  {
    int client = this.ToClient();
    if (!IsValidClient(client))
    {
      return;
    }

    Arena arena;
    arena = this.GetArena();

    SetHudTextParams(0.01, 0.01, 120.0, 255, 255, 255, 255);

    char report[256];
    Format(report, sizeof(report), "Arena %s\n%N : %i", arena.Name, client, arena.GetScore(client));

    Player opponent;
    opponent = this.GetOpponent();

    if (opponent.UserID != 0)
    {
      Format(report, sizeof(report), "%s\n%s : %i", report, opponent.Name, arena.GetScore(opponent.ToClient()));
    }

    ShowSyncHudText(client, hud_ArenaInfo, report);
  }

  void ShowSpecHud(int target)
  {
    // From target, we must get his arena, and then show the hud to us as if we were him, and his opponent
    Player targetPlayer;
    targetPlayer = GetPlayer(GetClientUserId(target));
    Arena arena;
    arena = targetPlayer.GetArena();

    char report[256];
    Format(report, sizeof(report), "Arena %s\n%N : %i", arena.Name, target, arena.GetScore(target));

    Player targetOpponent;
    targetOpponent = targetPlayer.GetOpponent();

    if (targetOpponent.UserID != 0)
    {
      int targetOpponentClient = targetOpponent.ToClient();
      Format(report, sizeof(report), "%s\n%N : %i", report, targetOpponentClient, arena.GetScore(targetOpponentClient));
    }
    SetHudTextParams(0.01, 0.01, 120.0, 255, 255, 255, 255);
    ShowSyncHudText(this.ToClient(), hud_ArenaInfo, report);
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
  int CountdownValue;
  Handle CountdownTimer;
  int RedScore;
  int BluScore;
  
  void AddScore(int client) {
    // Determine team and increment appropriate score
    TFTeam team = TF2_GetClientTeam(client);
    if (team == TFTeam_Red) {
      this.RedScore++;
    } else {
      this.BluScore++;
    }
    
    // Store updated arena
    g_Arenas.SetArray(this.Id - 1, this);
  }

  int GetScore(int client)
  {
    TFTeam team = TF2_GetClientTeam(client);
    if (team == TFTeam_Red)
    {
      return this.RedScore;
    }
    return this.BluScore;
  }

  void SetStatus(ArenaStatus status)
  {
    this.Status = status;
    g_Arenas.SetArray(this.Id - 1, this);
  }
  
  bool HasWinner() {
    return (this.RedScore >= this.FragLimit || this.BluScore >= this.FragLimit);
  }
  
  TFTeam GetWinningTeam() {
    if (this.RedScore >= this.FragLimit)return TFTeam_Red;
    if (this.BluScore >= this.FragLimit)return TFTeam_Blue;
    return TFTeam_Unassigned;
  }
  
  void BlockWeapons(int client, float duration)
  {
    float gameTime = GetGameTime();
    for (int slot = 0; slot <= 2; slot++) {
      int weapon = GetPlayerWeaponSlot(client, slot);
      if (IsValidEntity(weapon)) {
        SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", gameTime + duration);
      }
    }
  }
  
  void StartDuel(float interval)
  {
    CreateTimer(interval, Timer_StartCountdown, this.Id);
    this.ResetPlayers(interval);

    this.RedScore = 0;
    this.BluScore = 0;

    // Update arena in global array
    g_Arenas.SetArray(this.Id - 1, this);
  }

  void ResetPlayers(float interval)
  {
    for (int i = 0; i < this.Players.Length; i++) {
      Player player;
      this.Players.GetArray(i, player);
      DataPack pack = new DataPack();
      pack.WriteCellArray(player, sizeof(player));
      CreateTimer(interval, Timer_ResetPlayer, pack);
    }
  }

  void StartCountdown()
  {
    // Set initial countdown value 
    this.CountdownValue = this.CountdownTime;
    
    // Set arena status
    this.Status = Arena_Countdown;
    
    // Block weapons for all players
    for (int i = 0; i < this.Players.Length; i++) {
      Player player;
      this.Players.GetArray(i, player);
      int client = player.ToClient();
      if (IsValidClient(client)) {
        this.BlockWeapons(client, float(this.CountdownValue + 1));
      }
    }
    
    // Kill existing timer if any
    if (this.CountdownTimer != null) {
      delete this.CountdownTimer;
    }
    
    // Store arena ID in a static variable instead of DataPack
    static int currentArenaId;
    currentArenaId = this.Id;
    
    // Create timer and pass arena ID directly
    this.CountdownTimer = CreateTimer(1.0, Timer_Countdown, currentArenaId, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    
    // Update arena in global array
    g_Arenas.SetArray(this.Id - 1, this);
  }
  
  SpawnPoint GetRandomSpawn()
  {
    SpawnPoint coords;
    this.SpawnPoints.GetArray(GetRandomInt(0, this.SpawnPoints.Length - 1), coords);
    return coords;
  }
  
  bool IsClassAllowed(TFClassType class)
  {
    for (int i = 0; i < this.AllowedClasses.Length; i++)
    {
      if (this.AllowedClasses.Get(i) == class)
      {
        return true;
      }
    }
    return false;
  }
  
  SpawnPoint GetBestSpawnPoint(Player player)
  {
    // If no players in arena or only 1 player, return any random spawn
    if (this.Players.Length <= 1)
    {
      return this.GetRandomSpawn();
    }
    
    // Create array to store randomized spawn indices
    ArrayList randomizedSpawns = new ArrayList();
    
    // Fill array with spawn indices
    for (int i = 0; i < this.SpawnPoints.Length; i++)
    {
      randomizedSpawns.Push(i);
    }
    
    // Randomly shuffle the indices
    randomizedSpawns.Sort(Sort_Random, Sort_Integer);
    
    // Get opponent's position
    Player opponent;
    float opponentPos[3];
    
    // Find opponent (first player that isn't us)
    for (int i = 0; i < this.Players.Length; i++)
    {
      this.Players.GetArray(i, opponent);
      if (opponent.UserID != player.UserID)
      {
        int opponentClient = GetClientOfUserId(opponent.UserID);
        if (IsValidClient(opponentClient))
        {
          GetClientAbsOrigin(opponentClient, opponentPos);
          break;
        }
      }
    }
    
    // Go through each spawn point in random order and check distance from opponent
    float bestDistance = 0.0;
    SpawnPoint bestSpawn;
    
    for (int i = 0; i < randomizedSpawns.Length; i++)
    {
      SpawnPoint spawn;
      this.SpawnPoints.GetArray(randomizedSpawns.Get(i), spawn);
      
      float spawnPos[3];
      spawnPos[0] = spawn.OriginX;
      spawnPos[1] = spawn.OriginY;
      spawnPos[2] = spawn.OriginZ;
      
      float distance = GetVectorDistance(spawnPos, opponentPos);
      
      // If spawn is far enough away, use it immediately
      if (distance > this.MinimumDistance)
      {
        delete randomizedSpawns;
        return spawn;
      }
      
      // Otherwise track the farthest spawn as fallback
      if (distance > bestDistance)
      {
        bestDistance = distance;
        bestSpawn = spawn;
      }
    }
    
    delete randomizedSpawns;
    
    // Return the farthest spawn if no spawns met minimum distance
    return bestSpawn;
  }
  
  void AddPlayer(Player player)
  {
    this.Players.PushArray(player);
  }
  
  void RemovePlayer(Player player)
  {
    if (this.Players == null)
    {
      this.Players = new ArrayList(sizeof(Player));
    }
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

  RegPluginLibrary("mge");

  return APLRes_Success;
}

public void OnPluginStart()
{
  // MGE commands
  RegConsoleCmd("sm_add", CMD_Add, "Usage: add <arena number/arena name>. Add to an arena.");
  RegConsoleCmd("sm_remove", CMD_Remove, "Remove from current arena.");
  RegConsoleCmd("sm_debugplayers", CMD_DebugPlayers);
  RegConsoleCmd("sm_debugarenas", CMD_DebugArenas);
  RegAdminCmd("sm_botme", CMD_AddBot, ADMFLAG_GENERIC, "Add bot to your arena");

  // TF2 commands we intercept and/or override 
  RegConsoleCmd("autoteam", CMD_AutoTeam);
  RegConsoleCmd("jointeam", CMD_JoinTeam);
  RegConsoleCmd("joinclass", CMD_JoinClass);
  RegConsoleCmd("join_class", CMD_JoinClass);
  RegConsoleCmd("kill", CMD_Kill);
  RegConsoleCmd("eureka_teleport", CMD_EurekaTeleport);
  RegConsoleCmd("spec_prev", CMD_Spec);
  RegConsoleCmd("spec_next", CMD_Spec);
  
  g_Players = new ArrayList(sizeof(Player));
  hud_ArenaInfo = CreateHudSynchronizer();
  
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

public Action CMD_Spec(int client, int args)
{
  if (IsValidClient(client))
  {
    CreateTimer(0.1, Timer_ChangeSpecTarget, GetClientUserId(client));
  }
  return Plugin_Continue;
}

public Action CMD_EurekaTeleport(int client, int args)
{
  return Plugin_Handled;
}

public Action CMD_AddBot(int client, int args) {
  // Get requesting player
  Player player;
  player = GetPlayer(GetClientUserId(client));
  
  // Make sure player is in an arena
  if (player.ArenaId == 0) {
    PrintToChat(client, "You must be in an arena to add a bot!");
    return Plugin_Handled;
  }
  
  // Check if player already has a bot requested
  if (player.BotRequested) {
    PrintToChat(client, "You already have a bot request pending!");
    return Plugin_Handled;
  }
  
  // Default to Scout if no class specified
  TFClassType botClass = TFClass_Scout;
  
  // If class was specified, validate and use it
  if (args > 0) {
    char arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    
    TFClassType requestedClass = TF2_GetClass(arg1);
    if (requestedClass == TFClass_Unknown) {
      ReplyToCommand(client, "[SM] Invalid class specified. Usage: !botme [class]");
      return Plugin_Handled;
    }
    botClass = requestedClass;
  }
  
  // Store the chosen class for the bot
  g_Players.Set(player.Index, botClass, Player::BotClass);
  
  // Mark player as requesting a bot
  g_Players.Set(player.Index, true, Player::BotRequested);
  
  // Prevent bot from being kicked
  FindConVar("tf_bot_quota").SetInt(1);
  FindConVar("tf_bot_quota_mode").SetString("normal");
  FindConVar("tf_bot_join_after_player").SetInt(0);
  FindConVar("tf_bot_auto_vacate").SetInt(0);
  
  // Add bot with debugging
  ServerCommand("tf_bot_add");
  PrintToChat(client, "Requesting bot for arena %d...", player.ArenaId);
  
  return Plugin_Handled;
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

public Action CMD_DebugArenas(int client, int args) {
  bool full = args > 0;
  Debug("\n========= ARENA DEBUG INFO (tick %.1f) =========", GetTickedTime());
  
  for (int i = 0; i < g_Arenas.Length; i++) {
    Arena arena;
    g_Arenas.GetArray(i, arena);
    
    char statusString[32];
    switch (arena.Status) {
      case Arena_Fight:statusString = "FIGHT";
      case Arena_Idle:statusString = "IDLE";
      case Arena_Countdown:statusString = "COUNTDOWN";
      default:statusString = "UNKNOWN";
    }
    
    Debug("\n[ARENA %d] %s", arena.Id, arena.Name);
    Debug("├─ Status: %s", statusString);
    Debug("├─ Players (%d):", arena.Players.Length);
    
    if (arena.Players.Length == 0) {
      Debug("│  └─ No players");
    } else {
      // Get players from arena's player list, not global player list
      for (int j = 0; j < arena.Players.Length; j++) {
        Player player;
        arena.Players.GetArray(j, player);
        
        bool isLast = (j == arena.Players.Length - 1);
        Debug("│  %s─ %s (ID: %d)", isLast ? "└" : "├", player.Name, player.UserID);
        Debug("│  %s  ├─ UserID: %d", isLast ? " " : "│", player.UserID);
        Debug("│  %s  └─ ArenaID: %d", isLast ? " " : "│", player.ArenaId);
      }
    }
    
    if (full) {
      Debug("└─ Spawnpoints (%d):", arena.SpawnPoints.Length);
      for (int k = 0; k < arena.SpawnPoints.Length; k++) {
        SpawnPoint point;
        arena.SpawnPoints.GetArray(k, point);
        bool isLast = (k == arena.SpawnPoints.Length - 1);
        Debug("   %s─ Origin: %.1f, %.1f, %.1f", 
          isLast ? "└" : "├", 
          point.OriginX, 
          point.OriginY, 
          point.OriginZ
          );
      }
    }
  }
  
  Debug("\n============================================\n");
  return Plugin_Handled;
}

public void OnMapStart()
{
  LoadArenas();

  HookEvent("teamplay_round_start", Event_OnRoundStart, EventHookMode_Post);
  HookEvent("player_death", Event_OnPlayerDeath, EventHookMode_Pre);
  HookEvent("player_spawn", Event_OnPlayerSpawn, EventHookMode_Post);
  HookEvent("player_hurt", Event_OnPlayerHurt, EventHookMode_Pre);
  HookEvent("player_team", Event_OnPlayerJoinTeam, EventHookMode_Pre);
  HookEvent("teamplay_win_panel", Event_OnWinPanelDisplay, EventHookMode_Post);
  
  FindConVar("mp_autoteambalance").SetInt(0);
  FindConVar("mp_teams_unbalance_limit").SetInt(32);
  FindConVar("mp_tournament").SetInt(0);
  FindConVar("tf_player_movement_restart_freeze").SetInt(0);

  PrecacheSound(AN_THREE);
  PrecacheSound(AN_TWO); 
  PrecacheSound(AN_ONE);
  PrecacheSound(AN_FIGHT);
}

public Action Event_OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
  FindConVar("mp_waitingforplayers_cancel").SetInt(1);
  return Plugin_Continue;
}

public Action Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
  // Skip if it's a dead ringer death
  if (event.GetInt("death_flags") & 32)
  {
      return Plugin_Continue;
  }

  // Get victim
  int victimId = event.GetInt("userid");
  if (!IsValidClient(GetClientOfUserId(victimId)))
  {
    return Plugin_Continue;
  }

  Player victim;
  victim = GetPlayer(victimId);
  
  // Make pack
  DataPack pack = new DataPack();
  pack.WriteCellArray(victim, sizeof(victim));

  // Get arena
  Arena arena;
  arena = victim.GetArena();

  // Get opponent
  Player opponent;
  opponent = victim.GetOpponent();

  // Check for arena status, victim arena ID and opponent validity
  if (arena.Status != Arena_Fight || victim.ArenaId == 0 || opponent.UserID == 0) {
    CreateTimer(0.1, Timer_ResetPlayer, pack);
    return Plugin_Continue;
  }

  // Regen opponent and refresh hud
  int opponentClient = opponent.ToClient();
  if (IsValidClient(opponentClient)) {
    RequestFrame(RegenKiller, opponent.UserID);
  }

  // Add score to arena
  arena.AddScore(opponentClient);

  // Check if this death results in a win
  if (arena.HasWinner()) {
    // Get winning team
    TFTeam winningTeam = arena.GetWinningTeam();
    char winningTeamString[16];
    switch (winningTeam) {
      case TFTeam_Red: winningTeamString = "RED";
      case TFTeam_Blue: winningTeamString = "BLU";
      default: winningTeamString = "UNKNOWN";
    }

    // Announce winner
    for (int i = 0; i < arena.Players.Length; i++) {
      Player player;
      arena.Players.GetArray(i, player);
      int client = player.ToClient();
      if (IsValidClient(client)) {
        PrintCenterText(client, "WINNER: %s", winningTeamString);
      }
    }

    // Reset arena
    arena.StartDuel(3.0);
  } else {
    CreateTimer(0.1, Timer_ResetPlayer, pack);
  }

  // Refresh hud to killer
  opponent.ShowPlayerHud();

  return Plugin_Continue;
}

public void RegenKiller(int attacker) {
  TF2_RegeneratePlayer(GetClientOfUserId(attacker));
}

public Action Event_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
  /*
    - Set player HP (take HP ratio in account)
    - Restore ammo count
    - 
  */
  return Plugin_Continue;
}

public Action Event_OnPlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
  /*
    - ENDIF calculations idk
    - Expose to forwards for logging
  */
  return Plugin_Continue;
}

public Action Event_OnPlayerJoinTeam(Event event, const char[] name, bool dontBroadcast)
{
  int userid = event.GetInt("userid");
  int client = GetClientOfUserId(userid);
  if (!client)
  {
    return Plugin_Continue;
  }
  TFTeam team = view_as<TFTeam>(event.GetInt("team"));
  
  if (team == TFTeam_Spectator)
  {
    // Set arena back to idle if it wasn't
    Player player;
    player = GetPlayer(userid);
    
    // If player is not in an arena, do nothing
    if (player.ArenaId == 0)
    {
      return Plugin_Continue;
    }

    Arena arena;
    arena = player.GetArena();
    
    // If this player requested a bot, kick it
    if (player.BotRequested)
    {
      // Find and kick the bot in this arena
      for (int i = 1; i <= MaxClients; i++)
      {
        if (IsValidClient(i) && IsFakeClient(i))
        {
          Player botPlayer;
          botPlayer = GetPlayer(GetClientUserId(i));
          if (botPlayer.ArenaId == player.ArenaId)
          {
            KickClient(i, "Bot requester went to spectator");
            // Reset the bot request flag
            g_Players.Set(player.Index, false, Player::BotRequested);
            break;
          }
        }
      }
    }
    
    if (arena.Status == Arena_Fight)
    {
      arena.SetStatus(Arena_Idle);
    }
    RemoveFromQueue(client, false);
  }
  
  event.BroadcastDisabled = true;
  return Plugin_Changed;
}

public Action Event_OnWinPanelDisplay(Event event, const char[] name, bool dontBroadcast)
{
  /*
    - Disable stats so people leaving at the end of the map don't lose points.
  */
  return Plugin_Continue;
}

void LoadArenas()
{
  g_Arenas = new ArrayList(sizeof(Arena));
  
  char txtFile[256];
  char map[32];
  GetCurrentMap(map, sizeof(map));
  BuildPath(Path_SM, txtFile, sizeof(txtFile), "configs/mge/%s.cfg", map);
  
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
  if (IsFakeClient(client))
  {
    Debug("Bot %N connected", client);
    
    // Make sure bot won't get kicked
    SetEntityFlags(client, GetEntityFlags(client) | FL_FAKECLIENT);
    
    // Create a player entry for the bot
    Player bot;
    bot.Fill(client);
    g_Players.PushArray(bot);
    
    // Find player who requested bot
    Player requester;
    for (int i = 0; i < g_Players.Length; i++)
    {
      g_Players.GetArray(i, requester);
      if (requester.BotRequested)
      {
        Debug("Found requester: %s in arena %d", requester.Name, requester.ArenaId);
        
        // Reset the BotRequested flag BEFORE adding the bot
        g_Players.Set(i, false, Player::BotRequested);
        
        // Add bot immediately instead of using timer
        Debug("Adding bot %N directly to arena %d", client, requester.ArenaId);
        AddToQueue(client, requester.ArenaId);
        break;
      }
    }
    return;
  }
  
  // Normal player handling
  Player player;
  player.Fill(client);
  g_Players.PushArray(player);
  
  TF2_ChangeClientTeam(client, TFTeam_Spectator);
}

public Action Timer_ChangeSpecTarget(Handle timer, int userid)
{
  int client = GetClientOfUserId(userid);
  if (!IsValidClient(client))
  {
    return Plugin_Stop;
  }
  
  int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
  if (IsValidClient(target))
  { 
    Player player;
    player = GetPlayer(userid);
    player.ShowSpecHud(target);
  }
  
  return Plugin_Stop;
}

public Action Timer_AddBotToQueue(Handle timer, DataPack pack)
{
  pack.Reset();
  int botUserId = pack.ReadCell();
  int arenaId = pack.ReadCell();
  delete pack;
  
  int bot = GetClientOfUserId(botUserId);
  if (!IsValidClient(bot))
  {
    Debug("Bot became invalid before adding to queue");
    return Plugin_Stop;
  }
  
  Debug("Adding bot %N to arena %d", bot, arenaId);
  AddToQueue(bot, arenaId);
  
  return Plugin_Stop;
}

public Action Timer_StartCountdown(Handle timer, int arenaId)
{
  // Get arena
  Arena arena;
  arena = GetArena(arenaId);
  
  // Validate arena
  if (arena.Id <= 0)
  {
    return Plugin_Stop;
  }
  
  // Start countdown
  arena.StartCountdown();
  
  return Plugin_Handled;
}

public Action Timer_Countdown(Handle timer, any arenaId) {
  // Get arena
  Arena arena;
  arena = GetArena(arenaId);
  
  // Validate arena 
  if (arena.Id == -1 || arena.Status != Arena_Countdown) {
    return Plugin_Stop;
  }
  
  // Show countdown messages if between 3 and 1
  if (arena.CountdownValue <= 3 && arena.CountdownValue >= 1) {
    char message[32];
    char soundFile[64];

    switch (arena.CountdownValue) {
      case 1: {
        message = "ONE";
        soundFile = AN_ONE;
      }
      case 2: {
        message = "TWO";
        soundFile = AN_TWO;
      }
      case 3: {
        message = "THREE";
        soundFile = AN_THREE;
      }
    }
    
    // Show to all players
    for (int i = 0; i < arena.Players.Length; i++) {
      Player player;
      arena.Players.GetArray(i, player);
      int client = player.ToClient();
      if (IsValidClient(client)) {
        PrintCenterText(client, message);
        EmitSoundToClient(client, soundFile);
      }
    }
  }
  // Countdown finished
  else if (arena.CountdownValue <= 0) {
    arena.Status = Arena_Fight;
    
    // Show fight message
    for (int i = 0; i < arena.Players.Length; i++) {
      Player player;
      arena.Players.GetArray(i, player);
      int client = player.ToClient();
      if (IsValidClient(client)) {
        PrintCenterText(client, "FIGHT!");
        EmitSoundToClient(client, AN_FIGHT);
      }
    }
    
    // Clear timer handle
    arena.CountdownTimer = null;
    
    // Update arena
    g_Arenas.SetArray(arenaId - 1, arena);
    
    return Plugin_Stop;
  }
  
  // Decrement countdown
  arena.CountdownValue--;
  g_Arenas.SetArray(arenaId - 1, arena);
  
  return Plugin_Continue;
}

public void OnClientDisconnect(int client)
{
  // Get player
  int userid = GetClientUserId(client);
  Player player;
  player = GetPlayer(userid);

  // Remove player from queue if he's in an arena
  if (player.ArenaId != 0)
  {
    RemoveFromQueue(client);
  }

  // Remove player from global list
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
    return Plugin_Continue;
  }
  else
  {
    Debug("Can't switch teams!");
    if (TF2_GetClientTeam(client) == TFTeam_Spectator)
    {
      ShowAddMenu(client);
    }
    return Plugin_Stop;
  }
}

public Action CMD_JoinClass(int client, int args)
{
  // Get selected client class
  char arg1[32];
  GetCmdArg(1, arg1, sizeof(arg1));
  TFClassType chosenClass = TF2_GetClass(arg1);
  
  if (chosenClass == TF2_GetPlayerClass(client))
  {
    return Plugin_Continue;
  }
  
  if (chosenClass == TFClass_Unknown)
  {
    return Plugin_Continue; // Let game handle invalid class names
  }
  
  // Get player
  Player player;
  player = GetPlayer(GetClientUserId(client));
  
  // If he's not on any arena, let them change
  if (player.ArenaId == 0)
  {
    return Plugin_Continue;
  }
  
  // Get arena
  Arena arena;
  arena = player.GetArena();
  
  // Block if class isn't allowed
  if (!arena.IsClassAllowed(chosenClass))
  {
    PrintToChat(client, "This class is not allowed in this arena!");
    return Plugin_Stop; // Block the class change
  }
  
  TF2_SetPlayerClass(client, chosenClass);
  if (IsPlayerAlive(client))
  {
    DataPack pack = new DataPack();
    pack.WriteCellArray(player, sizeof(player));
    CreateTimer(0.1, Timer_ResetPlayer, pack);
  }

  // Destroy all buildings
  player.DestroyBuildings();

  return Plugin_Handled;
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
  
  // Ignore if trying to add to the arena they're already at
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
      // Find first available position
      bool positionFound = false;
      for (int i = 0; i < 2; i++) {  // Only check first two positions for 1v1
        bool positionTaken = false;
        
        // Check if this position is taken
        for (int j = 0; j < arena.Players.Length; j++) {
          Player existingPlayer;
          arena.Players.GetArray(j, existingPlayer);
          int existingClient = GetClientOfUserId(existingPlayer.UserID);
          
          if (IsValidClient(existingClient)) {
            TFTeam existingTeam = TF2_GetClientTeam(existingClient);
            if ((i == 0 && existingTeam == TFTeam_Red) || 
              (i == 1 && existingTeam == TFTeam_Blue)) {
              positionTaken = true;
              break;
            }
          }
        }
        
        // Found free position
        if (!positionTaken) {
          if (i == 0) {
            TF2_ChangeClientTeam(client, TFTeam_Red);
          } else {
            TF2_ChangeClientTeam(client, TFTeam_Blue);
          }
          positionFound = true;
          break;
        }
      }
      
      // If no position found, something's wrong
      if (!positionFound) {
        TF2_ChangeClientTeam(client, TFTeam_Red);
      }
      
      // Set player's arena
      g_Players.Set(player.Index, arenaid, Player::ArenaId);
      player.ArenaId = arenaid;
      
      // Create pack for reset timer
      DataPack pack = new DataPack();
      pack.WriteCellArray(player, sizeof(player));
      
      // Push player to arena
      arena.AddPlayer(player);
      
      // Reset player
      CreateTimer(0.1, Timer_ResetPlayer, pack);
      
      // Start countdown if arena is full
      if (!arena.FourPlayers && arena.Players.Length == 2) {
        arena.Status = Arena_Fight;
        arena.StartDuel(1.5);
      }
    }
    case Arena_Fight:
    {
      arena.PlayerQueue.Push(GetClientUserId(client));
    }
  }
  
  player.CloseAddMenu();
}

void RemoveFromQueue(int client, bool forceTeamChange = true)
{
  
  // Only force team change if explicitly requested
  if (forceTeamChange && IsValidClient(client) && TF2_GetClientTeam(client) != TFTeam_Spectator)
  {
    ForcePlayerSuicide(client);
    TF2_ChangeClientTeam(client, TFTeam_Spectator);
  }
  
  // Rest of removal logic
  Player player;
  player = GetPlayer(GetClientUserId(client));
  
  g_Players.Set(player.Index, 0, Player::ArenaId);
  
  Arena arena;
  arena = player.GetArena();
  
  arena.RemovePlayer(player);
  arena.Status = Arena_Idle;
  g_Arenas.SetArray(arena.Id - 1, arena);
}

Action Timer_ResetPlayer(Handle timer, DataPack pack)
{
  pack.Reset();
  Player player;
  pack.ReadCellArray(player, sizeof(player));
  delete pack;
  
  player.Reset();
  
  return Plugin_Handled;
}

Action Timer_TeleportPlayer(Handle timer, DataPack pack)
{
  pack.Reset();
  Player player;
  pack.ReadCellArray(player, sizeof(player));
  delete pack;
  
  int client = player.ToClient();
  
  // Get arena
  Arena arena;
  arena = player.GetArena();
  
  // Get best spawn point based on opponent position
  SpawnPoint coords;
  coords = arena.GetBestSpawnPoint(player);
  
  float pointOrigin[3];
  pointOrigin[0] = coords.OriginX;
  pointOrigin[1] = coords.OriginY;
  pointOrigin[2] = coords.OriginZ;
  
  float pointAngles[3];
  pointAngles[0] = coords.AngleX;
  pointAngles[1] = coords.AngleY;
  pointAngles[2] = coords.AngleZ;
  
  float pointVelocity[3] = { 0.0, 0.0, 0.0 };
  
  // Teleport to the selected spawn point
  TeleportEntity(client, pointOrigin, pointAngles, pointVelocity);
  
  // Emit respawn sound
  EmitAmbientSound("items/spawn_item.wav", pointOrigin);

  // Update hud
  player.ShowPlayerHud();
  
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
  for (int i = 0; i < g_Players.Length; i++)
  {
    g_Players.GetArray(i, player);
    if (player.UserID == userid)
    {
      player.Index = i;
      return player;
    }
  }
  return player;
}

Arena GetArena(int arenaId)
{
  Arena arena;
  arena.Id = -1;
  for (int i = 0; i < g_Arenas.Length; i++)
  {
    g_Arenas.GetArray(i, arena);
    if (arena.Id == arenaId)
    {
      return arena;
    }
  }
  return arena;
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