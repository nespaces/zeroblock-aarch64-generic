# ZeroBlock на OpenWrt `aarch64_generic`

Скрипт для установки [ZeroBlock](https://routerich.ru) (маршрутизация трафика через прокси и VPN по спискам доменов) на роутеры OpenWrt с архитектурой `aarch64_generic`: Orange Pi, NanoPi, Rockchip, Raspberry Pi 3/4/5 и т. п.

## Зачем это нужно

Пакеты Routerich собраны под `aarch64_cortex-a53` (чипы MediaTek Filogic). На `aarch64_generic` `opkg` их не ставит: архитектура в метаданных не совпадает, хотя набор инструкций у этих CPU тот же (ARMv8.0).

`repack.sh` скачивает пакеты с официального фида Routerich и меняет в метаданных ровно одну строку, `Architecture:`. Содержимое пакета (бинарники, конфиги, LuCI) остаётся тем же, скрипт сверяет это после сборки и прерывается при любом расхождении.

**Бинарники в этом репозитории не хранятся.** Всё скачивается с сервера автора пакетов прямо у тебя на компьютере, а всё, что делает скрипт, можно прочитать за минуту.

> ⚠️ Неофициальный проект, не связан с Routerich и не поддерживается ими. Перепакованные пакеты не подписаны, ты ставишь их на свой риск.

## Проверено

| | |
|---|---|
| Устройство | Xunlong Orange Pi R1 Plus LTS (rockchip/armv8) |
| OpenWrt | 24.10.6, `DISTRIB_ARCH='aarch64_generic'` |
| ZeroBlock | 0.8.5-r121 + luci-app-zeroblock |
| sing-box | официальный 1.12.22-r1 из фида OpenWrt |
| Xray | 26.6.1 (см. ниже) |
| Подписка | VLESS, gRPC, Hysteria2 |

`sing-box-rr` (Routerich edition) скрипт тоже умеет репаковать, но на железе я его **не проверял**: у меня работает официальный `sing-box`.

## Требования

- Linux или WSL (нужны `curl`, **GNU** `tar`, `gzip`, `sed`, `sha256sum`). Busybox `tar` не подходит.
- Роутер с OpenWrt 24.10.x и доступом в интернет (зависимости `opkg` подтянет сам).

## Использование

```sh
git clone https://github.com/nespaces/zeroblock-aarch64-generic
cd zeroblock-aarch64-generic
./repack.sh                       # zeroblock, luci-app-zeroblock, sing-box-rr
# или выборочно:
./repack.sh zeroblock luci-app-zeroblock
```

Результат появится в `./out/`. Загрузи на роутер:

```sh
scp out/*.ipk root@192.168.1.1:/tmp/
```

И поставь на роутере:

```sh
opkg update
opkg install /tmp/zeroblock_*_aarch64_generic.ipk /tmp/luci-app-zeroblock_*_all.ipk
```

`opkg` сам докачает зависимости из официального фида (`libuci`, `libubus`, `nftables-json`, `kmod-nft-tproxy`, `conntrack` и др.). Если он ругается на `nftables-json`, а у тебя стоит `nftables-nojson`: `opkg remove nftables-nojson && opkg install nftables-json`.

> Хэши `.ipk` у твоей сборки будут отличаться от чужих (в tar пишется время создания). Это нормально: сверяй содержимое, а не хэш архива. Скрипт делает это сам.

## sing-box

ZeroBlock сам запускает и останавливает `sing-box`. Подойдёт официальный из фида OpenWrt:

```sh
opkg install sing-box
/etc/init.d/sing-box disable && /etc/init.d/sing-box stop   # ZeroBlock управляет им сам
```

Альтернатива: `./repack.sh sing-box-rr`. Он **конфликтует** с `sing-box` (`opkg remove sing-box` перед установкой) и нужен для Snell, Sudoku, XHTTP, mKCP.

## Xray и Hysteria2

Если в подписке есть Hysteria2, нужен Xray **с поддержкой `hysteria`**. Версия 25.1.30 из официального фида OpenWrt её не знает: ZeroBlock пишет `unknown transport protocol: hysteria`, а такие прокси помечает «disabled by xray per-proxy fallback». Без Hysteria2 в подписке достаточно `opkg install xray-core`.

Рабочий вариант — Xray 26.x от [yichya/openwrt-xray](https://github.com/yichya/openwrt-xray) (MPLv2; пакет `openwrt-xray`, `Provides: xray-core`). Routerich берёт его же: файл `openwrt-xray_26.6.1-1_aarch64_cortex-a53-aarch64_cortex-a53.ipk` лежит в [их git-репозитории, ветка `24.10.5`, папка `routerich`](https://github.com/routerich/packages.routerich/tree/24.10.5/routerich) (в HTTP-фиде его нет). Скачай его и пропусти через скрипт, он принимает локальные `.ipk`:

```sh
./repack.sh ./openwrt-xray_26.6.1-1_aarch64_cortex-a53-aarch64_cortex-a53.ipk
```

На роутере `xray-core` и `openwrt-xray` пишут в один файл `/usr/bin/xray`, поэтому сначала удали старый:

```sh
opkg remove xray-core
opkg install /tmp/openwrt-xray_26.6.1-1_aarch64_generic.ipk
xray version
```

## Как добавить подписку

Подписка живёт внутри секции маршрутизации: **«Секции маршрутизации» → Add Section → Connection Type: Proxy Server → Proxy Configuration Type: Subscription → Subscription URL**.

ZeroBlock гонит через прокси **только домены из списков секции** (community-списки, свои домены). Поэтому обычный чекер IP покажет твой настоящий адрес. Для проверки добавь `ifconfig.me` в домены секции и отключи DoH в браузере.

## После `sysupgrade`

Пакеты не переживут прошивку. Сохрани `/etc/config/zeroblock`, а пакеты поставь заново (повторно запусти `repack.sh`).

## Что делает скрипт и чего не делает

- Берёт `*.ipk` с `FEED` (по умолчанию `packages.routerich.ru/24.10/mediatek/filogic/routerich`) или из локальных файлов, которые ты сам передал.
- Меняет `Architecture:` на `ARCH` (по умолчанию `aarch64_generic`), пакует заново с владельцем `0:0`, сверяет payload.
- Ничего не ставит, не запускает и не лезет на роутер.
- Переменные: `FEED`, `SRC_ARCH`, `ARCH`, `OUT` (см. шапку `repack.sh`).

Если нужны другие архитектуры, поменяй `ARCH`, но проверь сам, что бинарники подходят: скрипт меняет только метку.

## Лицензия

Скрипт и README: MIT (см. `LICENSE`). Пакеты ZeroBlock и компонентов принадлежат их авторам и поставляются по их лицензиям; в этом репозитории они не распространяются.
