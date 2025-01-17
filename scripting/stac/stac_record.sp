#pragma semicolon 1

/*
Amount of detections needed to activate autorecord:
	- cmdnum spikes: 5
	- Triggerbot: 5
	- Aimsnaps: 5
	- pSilent: 3
*/

// prepare the SourceTV bot, set the cvars accordingly and block changes to them
void prepareSourceTV()
{
	// STV already prepared, dont hook cvars again!
	if (STVprepared)
	{
		if (stac_debug.BoolValue)
		{
			StacLog("STV setup aborted!");
		}
		return;
	}

	Handle sourcetvconvar;

	// We changed stv cvars - reset them on plugin end
	STVSettingsChanged = true;

	// Check for SourceTV and enable it
	if ((sourcetvconvar = FindConVar("tv_enable")) != null)
	{
		// save prev setting to restore after plugin unload
		Setting_tv_enable = GetConVarInt(sourcetvconvar);
		SetConVarInt(sourcetvconvar, 1, false, false);
		HookConVarChange(sourcetvconvar, STVconvarChanged);
		if (stac_debug.BoolValue)
		{
			StacLog("Successfully hooked \"tv_enable\".");
		}
	}
	else
	{	
		ThrowError("ConVar \"tv_enable\" not found!");
	}

	// check if sourcetv's autorecord is enabled
	if ((sourcetvconvar = FindConVar("tv_autorecord")) != null)
	{
		// stop the demo recording if one is active
		if (GetConVarInt(sourcetvconvar))
		{
			SourceTV_StopRecording();
		}
		// save prev setting to restore after plugin unload
		Setting_tv_autorecord = GetConVarInt(sourcetvconvar);

		SetConVarInt(sourcetvconvar, 0, false, false);
		HookConVarChange(sourcetvconvar, STVconvarChanged);
		if (stac_debug.BoolValue)
		{
			StacLog("Successfully hooked \"tv_autorecord\".");
		}
	}
	else
	{	
		ThrowError("ConVar \"tv_autorecord\" not found!");
	}

	// prevent idiots from spamming "Fredo is now controlling the camera" notifications
	if ((sourcetvconvar = FindConVar("tv_allow_camera_man")) != null)
	{
		// save prev setting
		Setting_tv_cameraman = GetConVarInt(sourcetvconvar);
		// No need for a hook - unimportant stv cvar
		SetConVarInt(sourcetvconvar, 0, false, false);
	}

	// set stv tickrate, but let people change it if they want.
	if ((sourcetvconvar = FindConVar("tv_snapshotrate")) != null)
	{
		// save prev tickrate setting
		Setting_tv_snapshotrate = GetConVarInt(sourcetvconvar);
		// No need for a hook - unimportant stv cvar
		int tickrate = RoundToCeil(1.0 / GetTickInterval());
		SetConVarInt(sourcetvconvar, tickrate, false, false);
	}

	STVprepared = true;

	TryConnectSTVbot();
}

void RequestRecording(int cl)
{
	// invalid client, no need to record
	if (!IsValidClient(cl))
	{
		return;
	}

	// this value gets increased everytime a detection "requests" a recording.
	// this way we can easly track if other clients/the same client triggered something worth recording
	recordClient[cl]++;

	int userid = GetClientUserId(cl);

	if (SourceTV_IsRecording())
	{
		CreateTimer(610.0, timer_updateClientRecordStatus, userid, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	// 10 min timer, after which it checks if more detections happend, or if the recording can end.
	CreateTimer(610.0, timer_updateClientRecordStatus, userid, TIMER_FLAG_NO_MAPCHANGE);

	StacStartRecording(cl);
}

// Start the recording and updates a few parameters.
// If you want to update a CLIENTS record status, call updateClientRecordStatus(userid) instead!
void StacStartRecording(cl)
{

	// get steamid64
	char steamid[MAX_AUTHID_LENGTH];
	GetClientAuthId(cl, AuthId_SteamID64, steamid, sizeof(steamid));

	// create file name for the recording.
	// Name will be:    year_month_day__hour_minute_seconds_steamid64.dem
	// Example:         2024_02-03__20_59_56_76561198815978603.dem
	char nowtime[64];
	int	 int_nowtime = GetTime();
	FormatTime(nowtime, sizeof(nowtime),
			   "%Y_%m_%d__%H_%M_%S", int_nowtime);

	char demopath[128];
	// set path
	BuildPath(Path_SM, demopath, sizeof(demopath), "logs/stac-demos");

	if (DirExists(demopath, false))
	{
		Format(fulldemoname, sizeof(fulldemoname), "%s/%s_%s.dem", demopath, nowtime, steamid); // logs/stac-demos/year_month_day__hour_minute_second_steamid.dem"
	}
	// create directory if not extant
	else
	{
		LogMessage("[StAC] StAC demo directory not extant! Creating...");
		static int perms = 0o775;
		if (!CreateDirectory(demopath, perms, false))
		{
			LogMessage("[StAC] StAC directory could not be created!");
			// Directory doesnt exist and creating it failed, so just record without setting a directory to let tf2 dump it into the default folder.
			Format(fulldemoname, sizeof(fulldemoname), "%s_%s.dem", nowtime, steamid); 
		}
	}

	// Start the recording
	if (!SourceTV_StartRecording(fulldemoname))
	{
		// log something if the dumb bot fails to record
		StacLog("ERROR: Auto recording failed! (unkown reason)");
		char srctverrormsg[64];
		Format(srctverrormsg, sizeof(srctverrormsg), " SourceTV failed to record player %N", cl);
		StacNotify(0, srctverrormsg);
		recordClient[cl] = 0;
		return;
	}

	// makes the status command output appear in the demo console
	FakeClientCommand(SourceTV_GetBotIndex(), "status");

	if (stac_debug.BoolValue)
	{
		StacLog("Initiated auto recording. File name: %s\n\
        Triggered by player: %N", fulldemoname, cl);
	}

	// kill the recording after 1h if it is still on for whatever reason
	// Demos longer than that would be a pain in the ass to review
	RecordTimer = CreateTimer(3600.0, timer_nukeRecording, TIMER_FLAG_NO_MAPCHANGE);
}

// Checks if the auto recording should keep going or not.
void updateClientRecordStatus(userid)
{
	if (!SourceTV_IsRecording())
	{
		return;
	}

	// get fresh cl index
	int cl = GetClientOfUserId(userid);

	// decrease the client record value by 2,
	// which essentially means after 10 min the recording will stop,
	// UNLESS you triggered at least two more detection of: cmdnumspk, psilent, tbot or aimsnp
	recordClient[cl] = recordClient[cl] >= 2 ? recordClient[cl] - 2 : 0;

	// check if other clients triggered anything worth recording
	// if not, stop the recording
	for (int i = 1; i <= MaxClients; i++)
	{
		if (recordClient[i] > 0)
		{
			return;
		}
	}
	StacStopRecording();
}

Action timer_updateClientRecordStatus(Handle Timer, any userid)
{
	updateClientRecordStatus(userid);
	return Plugin_Continue;
}

Action timer_nukeRecording(Handle Timer)
{
	if (!SourceTV_IsRecording())
	{
		return Plugin_Continue;
	}

	StacLog("Maxmium demo recording lentgh of 1h reached.");
	StacStopRecording();
	return Plugin_Continue;
}

// Stops the recording, if one is active.
void StacStopRecording()
{
	if (!SourceTV_IsRecording())
	{
		return;
	}

	// reset all clients record value
	// is usually 0 at this point anyway
	// mainly prevents map changes from breaking shit
	for (int i = 0; i <= MaxClients; i++)
	{
		recordClient[i] = 0;
	}
	SourceTV_StopRecording();
	StacLog("Demo completed!");
	StacLogDemo();

	// kill the 1h record timer
	delete RecordTimer;
}

// restore the previous stv server settings before stac_autorecord was enabled.
void RestoreSTVSettings()
{
	// we never messsed with the stv cvars in the first place.
	if (!STVSettingsChanged)
	{
		return;
	}
	
	Handle stvcvar;
	// set tv_enable to the previous value
	// we need to unhook, othwerwise we wouldnt be able to change it...
	if ((stvcvar = FindConVar("tv_enable")) != null)
	{
		UnhookConVarChange(stvcvar, STVconvarChanged);
		SetConVarInt(stvcvar, Setting_tv_enable, false, false);
	}

	if ((stvcvar = FindConVar("tv_autorecord")) != null)
	{	
		UnhookConVarChange(stvcvar, STVconvarChanged);
		SetConVarInt(stvcvar, Setting_tv_autorecord, false, false);
	}

	if ((stvcvar = FindConVar("tv_tv_allow_camera_man")) != null)
	{
		SetConVarInt(stvcvar, Setting_tv_cameraman, false, false);
	}

	if ((stvcvar = FindConVar("tv_snapshotrate")) != null)
	{
		SetConVarInt(stvcvar, Setting_tv_snapshotrate, false, false);
	}
}

void TryConnectSTVbot()
{	
	// stv bot already there
	if (SourceTV_GetBotIndex() != 0)
	{
		return;
	}

	// no players on the server, restart map to connect it
	if (GetClientCount() <= 0)
	{
		StacLog(" ----------------> RESTARTING MAP TO CONNECT STV BOT");
		ResetMap();
		return;
	}

	// check every 30min if we can restart the map
	RestartMapTimer = CreateTimer(1800.0, Timer_Maprestart, _, TIMER_REPEAT);
}

Action Timer_Maprestart(Handle timer)
{
	// stv bot appeared for mysterious reason?
	if (SourceTV_GetBotIndex() != 0)
	{
		delete RestartMapTimer;
		return Plugin_Continue;
	}

	if (GetClientCount() <= 0)
	{
		StacLog(" ----------------> RESTARTING MAP TO CONNECT STV BOT");
		// kill the repeating timer
		delete RestartMapTimer;
		ResetMap();
	}
	return Plugin_Continue;
}

void ResetMap()
{
	char mapname[256];
	GetCurrentMap(mapname, sizeof(mapname));
	ServerCommand("changelevel \"%s\"", mapname);
}