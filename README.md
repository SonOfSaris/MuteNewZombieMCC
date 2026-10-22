# MuteNewZombieMCC

Mutes the "New Zombie" announcer in Halo 3 Infection (Halo: The Master Chief Collection, PC).

Download from [Releases](https://github.com/SonOfSaris/MuteNewZombieMCC/releases/latest) and close the game first:
- **PowerShell (Windows):** double-click `Mute New Zombie.bat`. `Restore New Zombie.bat` undoes it.
- **Python 3.8+:** `python mute_new_zombie.py`. `--restore` undoes it.

Only that one sound in your own `halo3\fmod\pc\sfx.fsb` changes, and no game files are included. Verifying the game files in Steam also restores it. Use at your own risk: it's unknown how MCC's Easy Anti-Cheat treats the edited file. MIT licensed.
