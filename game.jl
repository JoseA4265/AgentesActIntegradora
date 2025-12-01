# ==============================================================================
# AMONG US - CLON MULTIJUGADOR EN JULIA (Server Autoritativo)
# ==============================================================================
using Sockets
using Serialization
using GLFW
using ModernGL
using LinearAlgebra
using Printf

# ==============================================================================
# 1. ESTRUCTURAS DE DATOS COMPARTIDAS (SERIALIZABLES)
# ==============================================================================

mutable struct Bomb
    id::Int
    x::Float64
    z::Float64
    active::Bool
    timer::Float64
    deactivated::Bool
    exploded::Bool
    carrier_id::Int # 0 si nadie la lleva, >0 es el ID del jugador
end

mutable struct PlayerState
    id::Int
    x::Float64
    y::Float64
    z::Float64
    yaw::Float64
    leg_l::Float64
    leg_r::Float64
    state::Symbol # :idle, :walk
    carrying_bomb_id::Int # 0 si nada
    color::Tuple{Float64, Float64, Float64}
end

mutable struct NPCState
    x::Float64
    z::Float64
    yaw::Float64
    state::Symbol
    leg_l::Float64
    leg_r::Float64
    mode::Symbol
    current_path_idx::Int
end

mutable struct GameState
    players::Dict{Int, PlayerState}
    npc::NPCState
    bombs::Vector{Bomb}
    game_over::Bool
    msg::String
end

# Comandos del cliente al servidor
struct ClientInput
    keys::Set{Int} # Teclas presionadas (usaremos códigos GLFW)
    dt::Float64
end

# Constantes
const WIN_W = 1280
const WIN_H = 720
const ROOM_SPACING = 20.0
const ROOM_SIZE = 14.0
const WALK_SPEED = 5.0
const TURN_SPEED = 120.0
const PICKUP_RANGE = 2.0 # Aumentado ligeramente para facilitar agarre

# ==============================================================================
# 2. LÓGICA DEL JUEGO (FÍSICAS Y ESTADO)
# ==============================================================================

function create_initial_state()
    # Bombas
    bombs = [
        Bomb(1, -ROOM_SPACING, 0.0, true, 120.0, false, false, 0),
        Bomb(2, 0.0, -1.5, true, 120.0, false, false, 0),
        Bomb(3, ROOM_SPACING, 0.0, true, 120.0, false, false, 0)
    ]
    
    # NPC
    npc = NPCState(0.0, 2.5, 0.0, :idle, 0.0, 0.0, :roam, 1)
    
    return GameState(Dict{Int, PlayerState}(), npc, bombs, false, "Esperando Jugadores...")
end

# Ruta del NPC
const NPC_PATH = [
    (0.0, 0.0), (0.0, 10.0), (-ROOM_SPACING, 10.0), (-ROOM_SPACING, 0.0),
    (-ROOM_SPACING, 10.0), (ROOM_SPACING, 10.0), (ROOM_SPACING, 0.0), (ROOM_SPACING, 10.0),
    (0.0, 10.0), (0.0, 0.0)
]

# Colisiones simples (AABB vs Point)
function check_wall_collision(x, z)
    # Definimos paredes simplificadas
    if x < -40 || x > 40 || z < -40 || z > 40
        return true
    end
    return false
end

function update_game_logic!(state::GameState, inputs::Dict{Int, ClientInput}, dt::Float64)
    if state.game_over; return; end

    # 1. Actualizar Jugadores
    for (pid, input) in inputs
        if !haskey(state.players, pid); continue; end
        p = state.players[pid]
        
        # Movimiento
        move_speed = 0.0
        if GLFW.KEY_W in input.keys || GLFW.KEY_UP in input.keys
            move_speed = WALK_SPEED
        elseif GLFW.KEY_S in input.keys || GLFW.KEY_DOWN in input.keys
            move_speed = -WALK_SPEED
        end

        turn_speed = 0.0
        if GLFW.KEY_A in input.keys || GLFW.KEY_LEFT in input.keys
            turn_speed = TURN_SPEED
        elseif GLFW.KEY_D in input.keys || GLFW.KEY_RIGHT in input.keys
            turn_speed = -TURN_SPEED
        end

        p.yaw += turn_speed * dt
        rad = deg2rad(p.yaw)
        dx = sin(rad) * move_speed * dt
        dz = cos(rad) * move_speed * dt

        if !check_wall_collision(p.x + dx, p.z + dz)
            p.x += dx
            p.z += dz
        end

        # Animación Piernas
        if move_speed != 0
            p.state = :walk
            t_anim = time() * 10
            p.leg_l = sin(t_anim) * 30
            p.leg_r = -sin(t_anim) * 30
        else
            p.state = :idle
            p.leg_l *= 0.9
            p.leg_r *= 0.9
        end

        # Interacción (Espacio) - Lógica simplificada para Server
        if GLFW.KEY_SPACE in input.keys
            # Soltar
            if p.carrying_bomb_id > 0
                b_idx = findfirst(b -> b.id == p.carrying_bomb_id, state.bombs)
                if b_idx !== nothing
                    b = state.bombs[b_idx]
                    b.carrier_id = 0
                    b.x = p.x + sin(rad)*0.8
                    b.z = p.z + cos(rad)*0.8
                    p.carrying_bomb_id = 0
                    
                    # Checar desactivación (Áreas verdes - Ejemplo: Centro derecha)
                    if (abs(b.x) > 17 && abs(b.z) < 3) 
                        b.deactivated = true
                        b.active = false
                    end
                end
            else
                # Agarrar
                for b in state.bombs
                    if !b.exploded && b.active && b.carrier_id == 0
                        dist = sqrt((p.x - b.x)^2 + (p.z - b.z)^2)
                        if dist < PICKUP_RANGE
                            b.carrier_id = p.id
                            p.carrying_bomb_id = b.id
                            break # Solo una a la vez
                        end
                    end
                end
            end
        end
    end

    # 2. Actualizar NPC (Lógica simple de patrulla)
    npc = state.npc
    target = NPC_PATH[npc.current_path_idx]
    dx = target[1] - npc.x
    dz = target[2] - npc.z
    dist = sqrt(dx^2 + dz^2)
    
    if dist < 0.2
        npc.current_path_idx = (npc.current_path_idx % length(NPC_PATH)) + 1
    else
        npc.yaw = rad2deg(atan(dx, dz))
        npc.x += (dx/dist) * 2.5 * dt
        npc.z += (dz/dist) * 2.5 * dt
        t_anim = time() * 8
        npc.leg_l = sin(t_anim) * 25
        npc.leg_r = -sin(t_anim) * 25
    end

    # 3. Bombas y Game Over
    for b in state.bombs
        if b.active && !b.deactivated
            b.timer -= dt
            if b.timer <= 0
                b.exploded = true
                b.active = false
                state.game_over = true
                state.msg = "GAME OVER: BOOM!"
            end
        end
        # Si alguien la lleva, actualizar pos
        if b.carrier_id > 0 && haskey(state.players, b.carrier_id)
            carrier = state.players[b.carrier_id]
            b.x = carrier.x
            b.z = carrier.z
        end
    end
end


# ==============================================================================
# 3. MOTOR GRÁFICO (OPENGL)
# ==============================================================================

function set_material(color)
    glMaterialfv(GL_FRONT_AND_BACK, GL_AMBIENT_AND_DIFFUSE, Float32[color[1], color[2], color[3], 1.0])
    glMaterialfv(GL_FRONT_AND_BACK, GL_SPECULAR, Float32[0.2, 0.2, 0.2, 1.0])
    glMaterialf(GL_FRONT_AND_BACK, GL_SHININESS, 32.0f0)
end

function draw_cube()
    glBegin(GL_QUADS)
    # Front
    glNormal3f(0,0,1); glVertex3f(-0.5,-0.5,0.5); glVertex3f(0.5,-0.5,0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(-0.5,0.5,0.5)
    # Back
    glNormal3f(0,0,-1); glVertex3f(-0.5,-0.5,-0.5); glVertex3f(-0.5,0.5,-0.5); glVertex3f(0.5,0.5,-0.5); glVertex3f(0.5,-0.5,-0.5)
    # Left
    glNormal3f(-1,0,0); glVertex3f(-0.5,-0.5,-0.5); glVertex3f(-0.5,-0.5,0.5); glVertex3f(-0.5,0.5,0.5); glVertex3f(-0.5,0.5,-0.5)
    # Right
    glNormal3f(1,0,0); glVertex3f(0.5,-0.5,-0.5); glVertex3f(0.5,0.5,-0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(0.5,-0.5,0.5)
    # Top
    glNormal3f(0,1,0); glVertex3f(-0.5,0.5,-0.5); glVertex3f(-0.5,0.5,0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(0.5,0.5,-0.5)
    # Bottom
    glNormal3f(0,-1,0); glVertex3f(-0.5,-0.5,-0.5); glVertex3f(0.5,-0.5,-0.5); glVertex3f(0.5,-0.5,0.5); glVertex3f(-0.5,-0.5,0.5)
    glEnd()
end

function draw_character(x, y, z, yaw, leg_l, leg_r, color, has_cargo)
    glPushMatrix()
    glTranslatef(x, y, z)
    glRotatef(yaw, 0, 1, 0)

    # Torso
    set_material(color)
    glPushMatrix()
    glTranslatef(0, 0.9, 0)
    glScalef(0.7, 1.0, 0.4)
    draw_cube()
    glPopMatrix()

    # Cabeza
    set_material((color[1]*1.2, color[2]*1.2, color[3]*1.2))
    glPushMatrix()
    glTranslatef(0, 1.6, 0)
    glScalef(0.5, 0.5, 0.5)
    draw_cube()
    glPopMatrix()

    # Piernas
    set_material(color)
    # Izq
    glPushMatrix()
    glTranslatef(-0.2, 0.4, 0)
    glRotatef(leg_l, 1, 0, 0)
    glTranslatef(0, -0.4, 0)
    glScalef(0.25, 0.8, 0.25)
    draw_cube()
    glPopMatrix()
    # Der
    glPushMatrix()
    glTranslatef(0.2, 0.4, 0)
    glRotatef(leg_r, 1, 0, 0)
    glTranslatef(0, -0.4, 0)
    glScalef(0.25, 0.8, 0.25)
    draw_cube()
    glPopMatrix()

    # Mochila/Carga
    if has_cargo
        set_material((1.0, 1.0, 0.0)) # Amarilla
        glPushMatrix()
        glTranslatef(0, 1.0, 0.35)
        glScalef(0.4, 0.4, 0.4)
        draw_cube()
        glPopMatrix()
    end

    glPopMatrix()
end

# Implementación manual de gluLookAt para Julia
function manual_gluLookAt(eyex, eyey, eyez, centerx, centery, centerz, upx, upy, upz)
    f = [centerx - eyex, centery - eyey, centerz - eyez]
    f = normalize(f)
    u = [upx, upy, upz]
    u = normalize(u)
    s = cross(f, u)
    s = normalize(s)
    u = cross(s, f)
    
    M = Float32[
         s[1]  u[1] -f[1]  0;
         s[2]  u[2] -f[2]  0;
         s[3]  u[3] -f[3]  0;
            0     0     0  1
    ]
    glMultMatrixf(M)
    glTranslatef(-Float32(eyex), -Float32(eyey), -Float32(eyez))
end

function render_scene(state::GameState, my_id::Int, window::GLFW.Window)
    # FIX MACOS RETINA: Usar FramebufferSize en lugar de WindowSize
    fb_w, fb_h = GLFW.GetFramebufferSize(window)
    glViewport(0, 0, fb_w, fb_h)
    
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
    glLoadIdentity()

    # Cámara
    cam_x, cam_z = 0.0, 0.0
    cam_yaw = 0.0
    
    if my_id != -1 && haskey(state.players, my_id)
        p = state.players[my_id]
        cam_x, cam_z, cam_yaw = p.x, p.z, p.yaw
    end
    
    if my_id == -1
        # Espectador
        manual_gluLookAt(0, 30, 20, 0, 0, 0, 0, 1, 0)
    else
        # Jugador
        ex = cam_x - 8 * sin(deg2rad(cam_yaw))
        ez = cam_z - 8 * cos(deg2rad(cam_yaw))
        manual_gluLookAt(ex, 10, ez, cam_x, 1, cam_z, 0, 1, 0)
    end

    # Suelo
    set_material((0.8, 0.8, 0.8))
    glBegin(GL_QUADS)
    glNormal3f(0,1,0)
    glVertex3f(-50, 0, -50)
    glVertex3f(50, 0, -50)
    glVertex3f(50, 0, 50)
    glVertex3f(-50, 0, 50)
    glEnd()

    # Deactivation Zones (Visual)
    set_material((0.5, 0.9, 0.5))
    glBegin(GL_QUADS)
    glNormal3f(0,1,0)
    glVertex3f(17, 0.05, -3)
    glVertex3f(23, 0.05, -3)
    glVertex3f(23, 0.05, 3)
    glVertex3f(17, 0.05, 3)
    glEnd()

    # Dibujar Jugadores
    for (pid, p) in state.players
        draw_character(p.x, p.y, p.z, p.yaw, p.leg_l, p.leg_r, p.color, p.carrying_bomb_id > 0)
    end

    # Dibujar NPC
    npc = state.npc
    draw_character(npc.x, 2.5, npc.z, npc.yaw, npc.leg_l, npc.leg_r, (0.9, 0.2, 0.2), false)

    # Dibujar Bombas (si no están siendo cargadas)
    for b in state.bombs
        if b.active && !b.exploded && b.carrier_id == 0
            color = b.deactivated ? (0.2, 1.0, 0.2) : (1.0, 1.0, 0.0)
            set_material(color)
            glPushMatrix()
            glTranslatef(b.x, 0.25, b.z)
            glScalef(0.5, 0.5, 0.5)
            draw_cube()
            glPopMatrix()
        end
    end
end


# ==============================================================================
# 4. MÓDULOS DE EJECUCIÓN (SERVER / CLIENT)
# ==============================================================================

function run_server(port::Int)
    println(">>> Iniciando SERVIDOR en el puerto $port")
    println(">>> Modo ESPECTADOR (Ventana abierta para ver el juego)")
    
    server = listen(IPv4(0), port)
    state = create_initial_state()
    
    clients = Dict{Int, TCPSocket}()
    client_inputs = Dict{Int, ClientInput}()
    next_id = 1

    # Tarea asíncrona para aceptar clientes
    @async begin
        while true
            sock = accept(server)
            id = next_id
            next_id += 1
            println(">>> Cliente conectado: ID $id")
            
            # Asignar color random
            color = (rand(), rand(), rand())
            state.players[id] = PlayerState(id, 0.0, 0.0, -5.0, 0.0, 0.0, 0.0, :idle, 0, color)
            clients[id] = sock

            @async begin
                try
                    while isopen(sock)
                        input = deserialize(sock) 
                        client_inputs[id] = input
                    end
                catch
                    println("Cliente $id desconectado")
                    delete!(state.players, id)
                    delete!(clients, id)
                    delete!(client_inputs, id)
                end
            end
        end
    end

    # Inicializar GLFW
    GLFW.Init()
    
    # HINTS IMPORTANTES PARA MACOS
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 2)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 1)
    
    # FIX: Usar solo 3 argumentos para ventana normal
    window = GLFW.CreateWindow(800, 600, "SERVER - SPECTATOR VIEW")
    
    GLFW.MakeContextCurrent(window)
    glEnable(GL_DEPTH_TEST)
    
    glMatrixMode(GL_PROJECTION)
    glLoadIdentity()
    # Frustum simple
    fov = 60.0; aspect = 800/600; zNear = 0.1; zFar = 100.0
    fh = tan(deg2rad(fov) / 2) * zNear
    fw = fh * aspect
    glFrustum(-fw, fw, -fh, fh, zNear, zFar)
    glMatrixMode(GL_MODELVIEW)

    last_time = time()
    
    while !GLFW.WindowShouldClose(window)
        now = time()
        dt = now - last_time
        last_time = now

        update_game_logic!(state, client_inputs, dt)
        
        # Enviar estado a clientes
        for (id, sock) in clients
            try
                serialize(sock, state)
            catch
                # Error de envío
            end
        end

        render_scene(state, -1, window)
        
        GLFW.SwapBuffers(window)
        GLFW.PollEvents()
        sleep(0.01)
    end
    
    GLFW.DestroyWindow(window)
end

function run_client(ip_str::String, port::Int)
    println(">>> Conectando a $ip_str:$port ...")
    
    sock = connect(IPv4(ip_str), port)
    println(">>> ¡Conectado!")

    GLFW.Init()
    # HINTS IMPORTANTES PARA MACOS
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 2)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 1)

    window = GLFW.CreateWindow(WIN_W, WIN_H, "CLIENTE - AMONG US JULIA")
    
    GLFW.MakeContextCurrent(window)
    glEnable(GL_DEPTH_TEST)

    glMatrixMode(GL_PROJECTION)
    glLoadIdentity()
    fov = 60.0; aspect = WIN_W/WIN_H; zNear = 0.1; zFar = 100.0
    fh = tan(deg2rad(fov) / 2) * zNear
    fw = fh * aspect
    glFrustum(-fw, fw, -fh, fh, zNear, zFar)
    glMatrixMode(GL_MODELVIEW)

    local_state = nothing
    
    @async begin
        while isopen(sock)
            try
                local_state = deserialize(sock)
            catch
                break
            end
        end
    end

    last_time = time()
    keys_pressed = Set{Int}()

    GLFW.SetKeyCallback(window, (_, key, scancode, action, mods) -> begin
        if action == GLFW.PRESS
            push!(keys_pressed, Int(key))
        elseif action == GLFW.RELEASE
            delete!(keys_pressed, Int(key))
        end
    end)

    while !GLFW.WindowShouldClose(window)
        if local_state === nothing
            GLFW.PollEvents()
            continue
        end

        now = time()
        dt = now - last_time
        last_time = now

        input = ClientInput(copy(keys_pressed), dt)
        try
            serialize(sock, input)
        catch
            println("Desconectado del servidor.")
            break
        end

        # Heurística para encontrar mi ID (el primer jugador en la lista si soy el único, o iterar)
        target_id = isempty(local_state.players) ? -1 : first(keys(local_state.players))
        
        if !isempty(local_state.msg)
            GLFW.SetWindowTitle(window, local_state.msg)
        end

        render_scene(local_state, target_id, window)

        GLFW.SwapBuffers(window)
        GLFW.PollEvents()
    end
    
    GLFW.DestroyWindow(window)
end

# ==============================================================================
# 5. PUNTO DE ENTRADA
# ==============================================================================

function main()
    if length(ARGS) < 1
        println("Uso:")
        println("  julia game.jl server <puerto>")
        println("  julia game.jl client <ip> <puerto>")
        return
    end

    mode = ARGS[1]

    if mode == "server"
        port = parse(Int, ARGS[2])
        run_server(port)
    elseif mode == "client"
        ip = ARGS[2]
        port = parse(Int, ARGS[3])
        run_client(ip, port)
    else
        println("Modo desconocido: $mode")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end