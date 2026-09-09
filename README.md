# drone_swarm

Autonomous drone swarm simulation on Erlang/OTP. Each drone is an
independent process (`gen_statem`) with a state life cycle; a separate
coordinator process splits the map into zones and distributes them among
drones.

The core idea of the project is **self-healing on two levels at once**:

| Level | What happens on failure |
|---|---|
| Process | A drone crashes → `supervisor` restarts a new process (`let it crash`) |
| Logical task | The coordinator notices the drone's death via `monitor` → reassigns its zones to live drones |

The coordinator also survives its **own crash**: after a restart it does
not reset its state, but polls all live drones through `workers_sup` and
rebuilds the assignment map (reconciliation), without losing map coverage.

## Architecture

```
drone_swarm_sup                     (one_for_one)
│
├── drone_swarm_coordinator         (gen_server)
│     holds #{drone_pid => {monitor_ref, [zone]}}, monitors drones
│
├── drone_swarm_chaos_monkey        (gen_server)
│     periodically kills a random drone; kill_coordinator/0 — manual
│
└── drone_swarm_workers_sup         (one_for_one)
      ├── drone_swarm_worker × N    (gen_statem)
      └── ...
```

### Drone life cycle (`gen_statem`)

```
idle --assign_zones--> active --battery_low--> charging --charging_done--> idle
```

- **idle** — alive, no task, waiting for zones from the coordinator.
- **active** — patrols assigned zones, holds a `battery_low` timer.
- **charging** — battery depleted, zones returned to the pool, timer back to `idle`.
- *(dead)* — not a separate state: the process just crashes, the supervisor starts a new one.

### Zone allocation

The coordinator keeps a `zone → drone` map and a pool of unassigned zones.
On a drone request (`get_drone`) it either hands out a chain of adjacent
free zones (`select_connected_zones/2`, BFS over the grid), or, if there
are no free zones, takes part of the zones from the most loaded drone
(`rebalance_zones/4`), keeping the taken zones connected. Losing a drone
(`DOWN` / `battery_low`) looks for a neighbor via `find_adjacent_drone/2`
and hands it the freed zones as one block — otherwise they go back to the
unassigned pool.

### Coordinator restart recovery (reconciliation)

1. `init/1` returns `{ok, State, {continue, resync}}`.
2. `handle_continue(resync, ...)` enumerates the live children of
   `workers_sup`, `monitor`s each one, asks for `{report_zones, self()}`
   and sets `resyncing = true` for a `?RESYNC_WINDOW` window (800 ms in
   prod, 2000 ms in tests).
3. Drones respond with `{zones_report, Pid, Zones}` — the coordinator
   rebuilds `zone_assignments` and subtracts occupied zones from the pool.
4. `get_drone` / `battery_low` / `zones_declined` messages that arrive
   during the window are deferred (`deferred`) and replayed after
   `resync_done`.
5. A drone that started charging right as the coordinator restarted
   reports an empty zone list on `report_zones` (a separate fix against
   duplicate zones after recovery).

## Configuration

`config/drone_swarm.config`:

| Key | Default | Description |
|---|---|---|
| `num_drones` | `5` | Number of drones in the swarm |
| `block_size` | `{10, 15}` | Size of a single map block |
| `grid_dim` | `{3, 3}` | Zone grid size (→ 9 zones) |
| `chaos_interval` | `7000` | Interval (ms) between chaos monkey drone kills |

## Running

```
rebar3 shell
```

This starts the supervision tree: coordinator, chaos monkey, N drones.
The logs show drone registration, zone assignments, and, once per
`chaos_interval`, a random drone kill and reassignment of its zones.

Kill the coordinator manually (to check reconciliation):

```erlang
drone_swarm_chaos_monkey:kill_coordinator().
```

## Tests

```
rebar3 eunit   # zone logic: is_adjacent, select_connected_zones, find_adjacent_drone
rebar3 ct      # Common Test suites below
```

- `drone_swarm_allocation_SUITE` — zone allocation on different grids
  (1×1, 1×5, 3×3, 6×4) and drone counts: full coverage, empty pool,
  `min(zones, drones)` drones busy.
- `drone_swarm_recovery_SUITE` — coordinator restart: map coverage is
  preserved (`test_restart_preserves_coverage`), and there is no zone
  duplication if the restart catches a drone in the `charging` state
  (`test_restart_while_charging`).

> Do not run `rebar3 ct` concurrently in two terminals — a race over
> `_build/` breaks the CT logger.

## Status

The OTP application core (drones, coordinator, supervision, chaos monkey,
self-healing on both levels, coordinator reconciliation) is implemented
and covered by tests. The web visualization (Cowboy + WebSocket + browser
map) and the Docker wrapper from the plan are not implemented yet.

## License

MIT — see [LICENSE](LICENSE).

---

# drone_swarm (ukrainian version)

Симуляція рою автономних дронів на Erlang/OTP. Кожен дрон — незалежний
процес (`gen_statem`) з життєвим циклом станів; окремий процес-координатор
ділить карту на зони та розподіляє їх між дронами.

Ключова ідея проєкту — **self-healing на двох рівнях одночасно**:

| Рівень | Що відбувається при збої |
|---|---|
| Процес | Дрон крашиться → `supervisor` рестартує новий процес (`let it crash`) |
| Логічна задача | Координатор через `monitor` помічає смерть дрона → перерозподіляє його зони на живі дрони |

Додатково координатор переживає **власний крах**: після рестарту він не
скидає стан, а опитує всіх живих дронів через `workers_sup` і відновлює
карту призначень (reconciliation), не втрачаючи покриття карти.

## Архітектура

```
drone_swarm_sup                     (one_for_one)
│
├── drone_swarm_coordinator         (gen_server)
│     тримає #{drone_pid => {monitor_ref, [zone]}}, monitor'ить дронів
│
├── drone_swarm_chaos_monkey        (gen_server)
│     періодично вбиває випадкового дрона; kill_coordinator/0 — вручну
│
└── drone_swarm_workers_sup         (one_for_one)
      ├── drone_swarm_worker × N    (gen_statem)
      └── ...
```

### Життєвий цикл дрона (`gen_statem`)

```
idle --assign_zones--> active --battery_low--> charging --charging_done--> idle
```

- **idle** — живий, без задачі, чекає призначення зон від координатора.
- **active** — патрулює призначені зони, тримає таймер `battery_low`.
- **charging** — батарея розряджена, зони віддані назад у пул, таймер до `idle`.
- *(мертвий)* — не окремий стан: процес просто падає, supervisor піднімає новий.

### Розподіл зон

Координатор веде мапу `зона → дрон` і пул незайнятих зон. При запиті дрона
(`get_drone`) він або віддає ланцюжок суміжних вільних зон
(`select_connected_zones/2`, BFS по сітці), або, якщо вільних зон немає,
забирає частину зон у найзавантаженішого дрона (`rebalance_zones/4`), так
щоб забрані зони лишались зв'язними. Втрата дрона (`DOWN` / `battery_low`)
шукає сусіда через `find_adjacent_drone/2` і віддає йому звільнені зони
цілим блоком — інакше вони повертаються в пул незайнятих.

### Відновлення координатора після рестарту (reconciliation)

1. `init/1` повертає `{ok, State, {continue, resync}}`.
2. `handle_continue(resync, ...)` перебирає живих дітей `workers_sup`,
   ставить кожному `monitor`, просить `{report_zones, self()}` і виставляє
   `resyncing = true` на вікно `?RESYNC_WINDOW` (800 мс у проді, 2000 мс у
   тестах).
3. Дрони відповідають `{zones_report, Pid, Zones}` — координатор
   відбудовує `zone_assignments` і віднімає зайняті зони з пулу.
4. Повідомлення `get_drone` / `battery_low` / `zones_declined`, що
   надійшли під час вікна, відкладаються (`deferred`) і програються після
   `resync_done`.
5. Дрон, що якраз почав заряджатись під час рестарту координатора, при
   `report_zones` віддає порожній список (окремий фікс від дублювання зон
   після відновлення).

## Конфігурація

`config/drone_swarm.config`:

| Ключ | Значення за замовчуванням | Опис |
|---|---|---|
| `num_drones` | `5` | Кількість дронів у рої |
| `block_size` | `{10, 15}` | Розмір одного блоку карти |
| `grid_dim` | `{3, 3}` | Розмір сітки зон (→ 9 зон) |
| `chaos_interval` | `7000` | Інтервал (мс) між вбивствами дрона chaos monkey |

## Запуск

```
rebar3 shell
```

Підніметься дерево нагляду: координатор, chaos monkey, N дронів. У логах
видно реєстрацію дронів, призначення зон, а раз на `chaos_interval` —
вбивство випадкового дрона та перерозподіл його зон.

Вбити координатора вручну (перевірити reconciliation):

```erlang
drone_swarm_chaos_monkey:kill_coordinator().
```

## Тести

```
rebar3 eunit   # логіка зон: is_adjacent, select_connected_zones, find_adjacent_drone
rebar3 ct      # Common Test suites нижче
```

- `drone_swarm_allocation_SUITE` — розподіл зон на різних сітках
  (1×1, 1×5, 3×3, 6×4) і кількості дронів: повне покриття, порожній пул,
  задіяно `min(зон, дронів)` дронів.
- `drone_swarm_recovery_SUITE` — рестарт координатора: покриття карти
  зберігається (`test_restart_preserves_coverage`), і немає дублювання
  зон, якщо дрон рестарт застав у стані `charging`
  (`test_restart_while_charging`).

> Не запускати `rebar3 ct` паралельно в двох терміналах — гонка за
> `_build/` ламає CT-логер.

## Статус

Ядро OTP-застосунку (дрони, координатор, supervision, chaos monkey,
self-healing на обох рівнях, reconciliation координатора) реалізоване й
покрите тестами. Веб-візуалізація (Cowboy + WebSocket + карта в браузері)
та Docker-обгортка з плану поки не реалізовані.

## Ліцензія

MIT — див. [LICENSE](LICENSE).
