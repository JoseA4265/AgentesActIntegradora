# SUS - Multiplayer en Julia

Un juego multijugador básico tipo *Among Us* implementado 100% en **Julia** usando **OpenGL**. Permite jugar en red local (LAN) con arquitectura Cliente-Servidor.

## Requisitos Previos

1.  Tener **Julia** instalado.
2.  Instalar las dependencias necesarias. Abre Julia y ejecuta:

<!-- end list -->

```julia
import Pkg
Pkg.add(["GLFW", "ModernGL"])
```

## Cómo Jugar

Abre tu terminal en la carpeta donde guardaste el archivo `game.jl` y elige tu modo de juego:

### 1\. Modo HOST (Crear partida y Jugar)

Usa este comando si quieres levantar el servidor y controlar al **Jugador 1 (Azul)** en la misma ventana.

```bash
julia game.jl host 2000
```

> Usa **W, A, S, D** para moverte y **ESPACIO** para interactuar.

### 2\. Modo CLIENTE (Unirse a una partida)

Usa este comando para unirte a una partida creada por un Host.

  * **Si juegas solo en tu PC (prueba local):**

    ```bash
    julia game.jl client 127.0.0.1 2000
    ```

  * **Si te unes a otra computadora en la misma red Wi-Fi:**
    Reemplaza `IP_DEL_HOST` por la dirección IP de la computadora que corrió el comando `host`.

    ```bash
    julia game.jl client IP_DEL_HOST 2000
    ```

### 3\. Modo ESPECTADOR (Cámara de Seguridad)

Usa este comando si solo quieres ver el mapa completo sin jugar (útil para pantallas grandes o debugging).

```bash
julia game.jl server 2000
```

## Jugar en Red Local (LAN)

Si quieres jugar con amigos en diferentes Macs conectadas al mismo Wi-Fi:

1.  **El Host (Quien crea la partida):**
    Debe averiguar su dirección IP local. En una terminal nueva escribe:

    ```bash
    ipconfig getifaddr en0
    ```

    *(Te dará un número como `192.168.1.XX`)*.

2.  **Permisos:**
    Al iniciar el Host por primera vez, macOS preguntará si quieres permitir conexiones de red entrantes. Debes darle clic a **Permitir (Allow)** para que tus amigos puedan entrar.

3.  **Los Clientes (Tus amigos):**
    Deben conectarse usando la IP que obtuvo el Host en el paso 1:

    ```bash
    julia game.jl client 192.168.1.XX 2000
    ```
