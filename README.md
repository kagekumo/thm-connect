# THM Connect

Este script conecta la VPN de TryHackMe dentro del namespace `thm`, separando la red del laboratorio de la que utilizan los programas abiertos fuera de él.

## Preparación

Necesitas OpenVPN, iptables y acceso a sudo. El script también utiliza Bash, iproute2, procps-ng y util-linux, que suelen estar presentes en una instalación de Linux de escritorio.

Descarga tu archivo de conexión desde TryHackMe, renómbralo a `thm.ovpn` y guárdalo junto a `thm-connect.sh`.

El script está configurado para salir a Internet por la interfaz `eno1`. Si tu equipo utiliza otra, abre `thm-connect.sh` y sustituye `eno1` por su nombre en la línea `readonly WAN_IF="eno1"`.

## Uso

Abre una terminal en la carpeta del script y ejecútalo:

```bash
bash ./thm-connect.sh
```

Cuando aparezca `Initialization Sequence Completed`, la VPN estará conectada. Deja el script funcionando en esa terminal y abre otra para entrar al namespace:

```bash
sudo ip netns exec thm bash
```

La segunda terminal abre una shell como root. Los comandos que ejecutes ahí podrán acceder a la red de THM a través de la VPN; los programas abiertos fuera del namespace seguirán usando su red habitual.

Para terminar la sesión, sal de la segunda terminal con `exit`. Después pulsa Ctrl+C en la terminal donde ejecutaste el script para detener OpenVPN. Ya puedes cerrar ambas terminales.

## Entrar con tu usuario

Si prefieres trabajar con tu usuario y usar sudo solo cuando lo necesites, puedes guardar este atajo en Fish. Ejecútalo una vez desde tu terminal habitual:

```fish
alias --save thm 'sudo ip netns exec thm sudo -u (id -un) -H bash'
```

A partir de entonces, con la VPN conectada, escribe `thm` en la segunda terminal. Entrarás con tu usuario en lugar de root. El alias queda guardado para futuras sesiones; abre la shell, pero no inicia la VPN.

## Comprobación

Dentro del namespace, puedes comprobar el túnel con `ip addr show tun0` y consultar las rutas con `ip route`. La interfaz `tun0` debe aparecer activa y con una dirección IP.

No publiques `thm.ovpn`: cada persona debe descargar el suyo desde su cuenta de TryHackMe.
