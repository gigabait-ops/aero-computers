# Aero computers

ComputerCraft programs from the Aero server (Minecraft 1.21.1, NeoForge,
CC:Tweaked + Create): a crafting fleet that crafts from a Create warehouse,
a MineColonies supplier, a drone flight controller, a mining turtle swarm
and a tuff farm.

Програми ComputerCraft із сервера Aero. Встановлення: одна команда в грі
(нижче), оновлення: `update`.

## Install

On the computer (or turtle, or pocket computer) in game:

```
wget run https://raw.githubusercontent.com/gigabait-ops/aero-computers/main/install.lua <role>
```

Without a role it lists them. The installer downloads the role's files,
writes the settings files once and reboots. Later, `update` downloads the
newest files again; your settings files are never overwritten, and files the
role no longer uses are removed.

## Roles

| Role | Runs on | What it does | Set up in |
| --- | --- | --- | --- |
| `crafting-controller` | computer with a wired modem | Takes craft orders, plans them (sub-crafts included), hands jobs to turtles and stations, paces warehouse orders | `settings.lua`, `recipe_policy.lua` |
| `crafting-turtle` | crafting turtle | Pulls the ingredients from the warehouse and crafts the controller's jobs | nothing: it finds its frogport, barrel and packager |
| `crafting-station` | computer at a machine | Mechanical crafter, saw, slicer, basin or compactor station | `settings.lua` (`kind`, `address`, ...) |
| `crafting-requester` | computer with a monitor | Warehouse rules: keeps stock by ordering crafts, exports and overflow | `config.lua`, `requests/*.lua` |
| `crafting-console` | computer with a monitor | Manual craft console and the Create clipboard checklist | `config.lua` |
| `colony` | computer next to the colony | Colony Supply: MineColonies requests become Create Stock Ticker orders | `install setup`, `config.lua`, `rules/` |
| `drone-master` | the drone's main computer | Flight controller: attitude, altitude, routes, autopilot | `fc_config.lua` |
| `drone-node` | one computer per propeller / thruster | Applies the master's targets to its actuator | nothing |
| `drone-pocket` | pocket computer or smart glasses | Drone remote, teleport pads, HUD and chat news | `set drone.master <id>`, `set drone.key <key>` |
| `drone-pad` | computer under a teleport pad | Teleport pad | `startup.lua` (pad name) |
| `mining-turtle` | mining turtle | One digger of the swarm | `kopach/config.lua` (`remote`) |
| `mining-inspector` | turtle | Checks the dug area | `kopach/config.lua` |
| `mining-tab` | the `drone-pocket` device | The swarm's remote, as a Mine tab | `kopach/config.lua` |
| `mining-base` | computer at the supply chests | Gives the turtles fuel and blocks, takes what they unload | `config.lua` |
| `tuf-farm` | computer with a monitor | Tuff farm: runs the factory lines by stock | `tuf/config.lua` |
| `tuf-agent` | computer at another store | Reports that store to the farm | `tuf/config.lua` |

## Needs

- CC:Tweaked and Create 6. The crafting roles also need
  the CC: Recipe Atlas mod (`require("recipes")`)
  and a Create Stock Ticker on the warehouse network.
- The shared modules `config`, `logger`, `ui` and `common.ui` (the CC UI kit).
  They come with the Tensa Aeronautics modpack as a datapack in the computers'
  ROM; the programs do not ship them.
- Peripherals depend on the role: Advanced Peripherals (chat box, player
  detector, smart glasses), Create Propulsion / Simulated for the drone,
  MineColonies for `colony`.

## Layout

```
install.lua      the installer
manifest.lua     role -> files (repo path -> path on the computer), generated
crafting/        controller, turtle, station, requester, console; lib/ = shared code
colony/          Colony Supply
drone/           master, node, pocket, pads
mining/          kopach swarm (turtles, tab) and its supply base
farms/           tuff farm
```

The drone's nodes take targets from any computer on its protocol: keep the
drone's computers on their own wireless range or ender modem setup you trust.
