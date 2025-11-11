# AgentesActIntegradora

Este es un proyecto de simulación de agentes en 3D desarrollado en Python, Julia, PyOpenGL y GLFW.

El escenario es un juego de supervivencia donde un jugador (agente azul) debe completar una misión de desactivación de bombas mientras es perseguido por un agente impostor autónomo (agente rojo).


## Objetivo del Juego

El objetivo del jugador es encontrar y desactivar las **3 bombas** (cubos amarillos) repartidas por el mapa antes de que se acabe su temporizador individual.

Para desactivar una bomba, el jugador debe:
1.  Acercarse a una bomba.
2.  Recogerla (con la barra espaciadora).
3.  Llevarla hasta una de las **zonas de desactivación** (los cuadrados verdes).
4.  Soltarla dentro de la zona (con la barra espaciadora).

### Condiciones de Derrota

El juego termina (GAME OVER) si ocurre una de las siguientes condiciones:
1.  **El impostor te atrapa:** Si el agente rojo (NPC) colisiona contigo.
2.  **Una bomba explota:** Si el temporizador de cualquier bomba llega a cero antes de que sea desactivada.

## ⌨️ Controles

* **Movimiento:** `W`, `A`, `S`, `D` o **Teclas de Flecha**
    * `W / Arriba`: Moverse hacia adelante
    * `S / Abajo`: Moverse hacia atrás
    * `A / Izquierda`: Girar a la izquierda
    * `D / Derecha`: Girar a la derecha
* **Acción:** `Barra Espaciadora`
    * **Recoger** una bomba (si estás cerca y no llevas nada).
    * **Soltar** la bomba que llevas.
* **Juego:**
    * `R`: Reiniciar el juego (después de perder).
    * `Esc`: Salir de la aplicación.

## 🤖 Características de los Agentes

El proyecto cuenta con dos tipos de agentes con comportamientos distintos:

### 1. Agente Jugador (Controlado por el Usuario)
* Agente de color **azul**.
* Controlado directamente por las entradas del teclado.
* Puede interactuar con los objetos "bomba" para recogerlos y soltarlos.
* Sus colisiones con las paredes están implementadas para limitar el movimiento.

### 2. Agente Impostor (NPC Autónomo)
* Agente de color **rojo**.
* Utiliza una **máquina de estados finitos** para definir su comportamiento:
    * **`ROAM` (Patrullaje):** El agente sigue una ruta predefinida (un `path`) que recorre los pasillos exteriores.
    * **`CHASE` (Persecución):** Si el jugador entra en la misma habitación que el impostor, este abandonará su patrullaje y comenzará a perseguir al jugador.
    * **`RETURN` (Retorno):** Si el jugador sale de la habitación y el impostor lo pierde de vista, este calculará el punto más cercano de su ruta de patrullaje y regresará a ella para continuar en modo `ROAM`.

## 🛠️ Instalación y Ejecución

Este proyecto utiliza `glfw` para la gestión de la ventana y `PyOpenGL` para el renderizado 3D.

### 1. Prerrequisitos
* Python 3.7 o superior
* `pip` y `venv` (recomendado)

### 2. Pasos para Ejecutar

1.  **Clonar el repositorio:**
    ```bash
    git clone [https://github.com/JoseA4265/AgentesActIntegradora.git](https://github.com/JoseA4265/AgentesActIntegradora.git)
    cd AgentesActIntegradora
    ```

2.  **Crear y activar un entorno virtual:**
    * En macOS / Linux:
        ```bash
        python3 -m venv .venv
        source .venv/bin/activate
        ```
    * En Windows:
        ```bash
        python -m venv .venv
        .\.venv\Scripts\activate
        ```

3.  **Instalar las dependencias:**
    El script `main.py` incluye un verificador de dependencias. Puedes instalarlas manualmente con:
    ```bash
    pip install glfw PyOpenGL PyOpenGL-accelerate numpy
    ```

4.  **Ejecutar el proyecto:**
    ```bash
    python main.py
    ```
