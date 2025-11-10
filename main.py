# (Full file — replace your existing main.py with this)
import sys
def _check_deps():
    missing = []
    try:
        import glfw  
    except Exception as e:
        missing.append(("glfw", e))
    try:
        from OpenGL.GL import glGetString  
    except Exception as e:
        missing.append(("PyOpenGL", e))
    try:
        import numpy  
    except Exception as e:
        missing.append(("numpy", e))
    if missing:
        print("\n[!] Faltan dependencias:\n")
        for name, err in missing:
            print(f"   - {name}: {repr(err)}")
        print("\nInstala en tu .venv:")
        print("  pip install glfw PyOpenGL PyOpenGL-accelerate numpy\n")
        sys.exit(1)
_check_deps()

import time, math
import numpy as np
import glfw
from OpenGL.GL import *
from OpenGL.GLU import *
from OpenGL.GLUT import (
    glutInit,
    glutBitmapCharacter,
    glutBitmapWidth,
    GLUT_BITMAP_HELVETICA_18,
)

WIN_W, WIN_H = 1280, 720
WALK_SPEED = 3.4
TURN_SPEED = 120.0
LEG_SWING_DEG = 28.0
LEG_SWING_SPEED = 6.0
SMOOTH_RETURN = 8.0
FLOOR_SIZE = 90.0
AGENT_RADIUS = 0.35
PICKUP_RANGE = 1.1

ROOM_SIZE = 14.0
ROOM_HALF = ROOM_SIZE / 2.0
ROOM_SPACING = 20.0

GAME_OVER = False

# Bomb class (now used for multiple bombs)
class Bomb:
    def __init__(self, x=0.0, z=-1.5, timer=120.0):
        self.active = True
        self.start_time = time.time()
        self.timer = timer  # seconds
        self.deactivated = False
        self.exploded = False
        self.carried = False
        self.world_pos = (x, 0.18, z)

    def remaining(self):
        if not self.active or self.deactivated or self.carried:
            return 0.0 if (self.deactivated or not self.active) else max(0, self.timer - (time.time() - self.start_time))
        elapsed = time.time() - self.start_time
        return max(0, self.timer - elapsed)

# Create 3 bombs positioned in the three room centers (left, center, right)
bombs = [
    Bomb(x=1, z=0.0, timer=120.0),
    Bomb(x=0.0, z=-1.5, timer=120.0),
    Bomb(x=-1, z=0.0, timer=120.0),
]

#deactivation square
deactivation_areas = [
    {"x0": -22.5, "z0": -2.5, "x1": -17.5, "z1": +2.5, "color": (120, 230, 120)},  # Room 1 center
    {"x0": +17.5, "z0": -2.5, "x1": +22.5, "z1": +2.5, "color": (120, 230, 120)},  # Room 3 center
]

def draw_square_areas():
    """Draw the deactivation zones as colored squares using the same style as room floors."""
    glDisable(GL_TEXTURE_2D)
    for area in deactivation_areas:
        x0, z0, x1, z1, color = area["x0"], area["z0"], area["x1"], area["z1"], area["color"]
        set_material(color, specular=(20, 20, 20), shininess=8)
        glBegin(GL_QUADS)
        glNormal3f(0, 1, 0)
        y = 1.1  # slightly above floor
        glVertex3f(x0, y, z0)
        glVertex3f(x1, y, z0)
        glVertex3f(x1, y, z1)
        glVertex3f(x0, y, z1)
        glEnd()

def cargo_in_deactivation_area(cx, cz):
    """Check if cargo center is within any deactivation area."""
    for area in deactivation_areas:
        if area["x0"] <= cx <= area["x1"] and area["z0"] <= cz <= area["z1"]:
            return True
    return False


class AgentState:
    def __init__(self):
        self.x, self.y, self.z = 0.0, 0.0, 0.0
        self.yaw = 0.0
        self.state = 'idle'
        # carrying_index: None if not carrying, else index into bombs list
        self.carrying_index = None
        self.leg_l = 0.0
        self.leg_r = 0.0
        self._t = 0.0
        # removed single cargo_world_pos — each bomb has its own world_pos

class NPCState:
    def __init__(self):
        self.x, self.y, self.z = 0.0, 0.0, 2.5
        self.yaw = 0.0
        self.state = 'idle'
        self.leg_l = 0.0
        self.leg_r = 0.0
        self._t = 0.0
        self.speed = 2.6
        
        self.path = [
            (0.0, 0.0),
            (0.0, 10.0),
            (-ROOM_SPACING, 10.0),
            (-ROOM_SPACING, 0.0),
            (-ROOM_SPACING, 10.0),
            (ROOM_SPACING, 10.0),
            (ROOM_SPACING, 0.0),
            (ROOM_SPACING, 10.0),
            (0.0, 10.0),
            (0.0, 0.0),
        ]
        self.current_idx = 1
        self.mode = "roam"
        self.return_idx = 1

agent = AgentState()
agent.z = -3.0  
npc = NPCState()

keys_down = set()
walls = []
room_floors = []
floor_tex = None  

def make_checkerboard_tex(size=256, checks=16):
    img = np.zeros((size, size, 3), dtype=np.uint8)
    step = size // checks
    for i in range(size):
        for j in range(size):
            if ((i // step) + (j // step)) % 2 == 0:
                img[i, j] = [205, 205, 210]
            else:
                img[i, j] = [170, 175, 180]
    tex_id = glGenTextures(1)
    glBindTexture(GL_TEXTURE_2D, tex_id)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT)
    gluBuild2DMipmaps(GL_TEXTURE_2D, GL_RGB, size, size, GL_RGB, GL_UNSIGNED_BYTE, img)
    glBindTexture(GL_TEXTURE_2D, 0)
    return tex_id

def set_material(diffuse, ambient=None, specular=(50,50,50), shininess=48):
    if ambient is None:
        ambient = tuple([c*0.45 for c in diffuse])
    glMaterialfv(GL_FRONT_AND_BACK, GL_AMBIENT, (*[c/255.0 for c in ambient], 1.0))
    glMaterialfv(GL_FRONT_AND_BACK, GL_DIFFUSE, (*[c/255.0 for c in diffuse], 1.0))
    glMaterialfv(GL_FRONT_AND_BACK, GL_SPECULAR, (specular[0]/255.0, specular[1]/255.0, specular[2]/255.0, 1.0))
    glMaterialf(GL_FRONT_AND_BACK, GL_SHININESS, shininess)

def draw_cube(w=1,h=1,d=1):
    w2,h2,d2 = w/2,h/2,d/2
    glBegin(GL_QUADS)
    glNormal3f(1,0,0)
    glVertex3f(+w2,-h2,-d2); glVertex3f(+w2,+h2,-d2); glVertex3f(+w2,+h2,+d2); glVertex3f(+w2,-h2,+d2)
    glNormal3f(-1,0,0)
    glVertex3f(-w2,-h2,+d2); glVertex3f(-w2,+h2,+d2); glVertex3f(-w2,+h2,-d2); glVertex3f(-w2,-h2,-d2)
    glNormal3f(0,1,0)
    glVertex3f(-w2,+h2,+d2); glVertex3f(+w2,+h2,+d2); glVertex3f(+w2,+h2,-d2); glVertex3f(-w2,+h2,-d2)
    glNormal3f(0,-1,0)
    glVertex3f(-w2,-h2,-d2); glVertex3f(+w2,-h2,-d2); glVertex3f(+w2,-h2,+d2); glVertex3f(-w2,-h2,+d2)
    glNormal3f(0,0,1)
    glVertex3f(-w2,-h2,+d2); glVertex3f(-w2,+h2,+d2); glVertex3f(+w2,+h2,+d2); glVertex3f(-w2,+h2,+d2)
    glNormal3f(0,0,-1)
    glVertex3f(+w2,-h2,-d2); glVertex3f(+w2,+h2,-d2); glVertex3f(-w2,+h2,-d2); glVertex3f(-w2,-h2,-d2)
    glEnd()

def draw_floor(tex_id):
    glEnable(GL_TEXTURE_2D)
    glBindTexture(GL_TEXTURE_2D, tex_id)
    set_material((215,215,220))
    glBegin(GL_QUADS)
    glNormal3f(0,1,0)
    s = FLOOR_SIZE
    rep = 42.0
    glTexCoord2f(0,0); glVertex3f(-s,0,-s)
    glTexCoord2f(rep,0); glVertex3f(+s,0,-s)
    glTexCoord2f(rep,rep); glVertex3f(+s,0,+s)
    glTexCoord2f(0,rep); glVertex3f(-s,0,+s)
    glEnd()
    glBindTexture(GL_TEXTURE_2D, 0)
    glDisable(GL_TEXTURE_2D)

def add_wall(cx, cy, cz, sx, sy, sz):
    walls.append((cx,cy,cz,sx,sy,sz))

def add_room_floor(x0,z0,x1,z1,color):
    room_floors.append((x0,z0,x1,z1,color))

def build_rooms():
    walls.clear(); room_floors.clear()
    wall_h = 3.0; th = 0.25
    room = ROOM_SIZE
    spacing = ROOM_SPACING
    door_w = 3.6
    xs = (-spacing, 0.0, +spacing)
    for x in xs:
        x0, x1 = x - room/2, x + room/2
        z0, z1 = -room/2, +room/2
        add_room_floor(x0, z0, x1, z1, (200,200,210) if x==0 else (195,205,210))
        seg = (room - door_w)/2.0
        add_wall(x - (door_w/2 + seg/2), wall_h/2, +room/2, seg, wall_h, th)
        add_wall(x + (door_w/2 + seg/2), wall_h/2, +room/2, seg, wall_h, th)
        add_wall(x, wall_h/2, -room/2, room, wall_h, th)
        side_seg = (room - door_w)
        offset = 0.0 if x==0 else (door_w*0.5 if x<0 else -door_w*0.5)
        add_wall(x - room/2, wall_h/2, 0.0 - offset, th, wall_h, side_seg)
        add_wall(x + room/2, wall_h/2, 0.0, th, wall_h, room)
    border = FLOOR_SIZE - 2.0
    add_wall(0.0, wall_h/2, +border, FLOOR_SIZE*2, wall_h, th)
    add_wall(0.0, wall_h/2, -border, FLOOR_SIZE*2, wall_h, th)
    add_wall(+border, wall_h/2, 0.0, th, wall_h, FLOOR_SIZE*2)
    add_wall(-border, wall_h/2, 0.0, th, wall_h, FLOOR_SIZE*2)

def draw_room_floors():
    glDisable(GL_TEXTURE_2D)
    for x0,z0,x1,z1,color_rgb in room_floors:
        set_material(color_rgb, specular=(20,20,20), shininess=8)
        glBegin(GL_QUADS)
        glNormal3f(0,1,0)
        y = 0.002
        glVertex3f(x0, y, z0)
        glVertex3f(x1, y, z0)
        glVertex3f(x1, y, z1)
        glVertex3f(x0, y, z1)
        glEnd()

def draw_walls():
    glDisable(GL_CULL_FACE)
    set_material((70,70,72), ambient=(40,40,45), specular=(25,25,25), shininess=16)
    for cx,cy,cz,sx,sy,sz in walls:
        glPushMatrix()
        glTranslatef(cx,cy,cz)
        glScalef(sx,sy,sz)
        draw_cube(1,1,1)
        glPopMatrix()
    glEnable(GL_CULL_FACE)

def draw_cargo_cube(b):
    glDisable(GL_CULL_FACE)
    if b.deactivated:
        color = (100, 220, 100)   # green when safe
    elif b.exploded:
        color = (240, 60, 60)     # red when exploded
    else:
        color = (240, 210, 80)    # normal yellow
    set_material(color)
    glPushMatrix()
    glScalef(0.35, 0.35, 0.35)
    draw_cube(1, 1, 1)
    glPopMatrix()
    glEnable(GL_CULL_FACE)

def glutLikeSphere(r=0.225, slices=14, stacks=14):
    for i in range(stacks):
        lat0 = math.pi * (-0.5 + float(i)/stacks)
        z0 = math.sin(lat0) * r
        zr0 = math.cos(lat0) * r
        lat1 = math.pi * (-0.5 + float(i+1)/stacks)
        z1 = math.sin(lat1) * r
        zr1 = math.cos(lat1) * r
        glBegin(GL_QUAD_STRIP)
        for j in range(slices+1):
            lng = 2 * math.pi * float(j)/slices
            x = math.cos(lng); y = math.sin(lng)
            glNormal3f(x*zr0/r, y*zr0/r, z0/r); glVertex3f(x*zr0, y*zr0, z0)
            glNormal3f(x*zr1/r, y*zr1/r, z1/r); glVertex3f(x*zr1, y*zr1, z1)
        glEnd()

def draw_humanoid(entity, torso_color, head_color, show_cargo=False, carrying=False):
    glDisable(GL_CULL_FACE)
    glPushMatrix()
    glTranslatef(entity.x, entity.y, entity.z)
    glRotatef(entity.yaw, 0,1,0)

    torso_h = 1.0
    torso_center_y = 0.9
    torso_bottom_y = torso_center_y - torso_h * 0.5  # 0.4
    torso_depth = 0.4

    set_material(torso_color)
    glPushMatrix()
    glTranslatef(0, torso_center_y, 0)
    glScalef(0.7, torso_h, torso_depth)
    draw_cube(1,1,1)
    glPopMatrix()

    set_material(head_color)
    glPushMatrix()
    glTranslatef(0, 1.75, 0)
    glutLikeSphere()
    glPopMatrix()

    leg_h = 0.4
    leg_depth = 0.22
    leg_half_depth = leg_depth / 2.0
    set_material(torso_color)

    glPushMatrix()
    glTranslatef(-0.18, torso_bottom_y, 0)
    glRotatef(entity.leg_l, 1,0,0)
    
    glPushMatrix()
    glTranslatef(0, -leg_h/2, 0)
    glScalef(0.22, leg_h, leg_depth)
    draw_cube(1,1,1)
    glPopMatrix()
    
    glPushMatrix()
    glTranslatef(0, -leg_h/2, leg_half_depth + 0.01)
    glScalef(0.22, leg_h, 0.015)
    draw_cube(1,1,1)
    glPopMatrix()
    glPopMatrix()


    glPushMatrix()
    glTranslatef(+0.18, torso_bottom_y, 0)
    glRotatef(entity.leg_r, 1,0,0)
    
    glPushMatrix()
    glTranslatef(0, -leg_h/2, 0)
    glScalef(0.22, leg_h, leg_depth)
    draw_cube(1,1,1)
    glPopMatrix()
    
    glPushMatrix()
    glTranslatef(0, -leg_h/2, leg_half_depth + 0.01)
    glScalef(0.22, leg_h, 0.015)
    draw_cube(1,1,1)
    glPopMatrix()
    glPopMatrix()

    set_material(torso_color)
    glPushMatrix()
    glTranslatef(0, torso_center_y, (torso_depth/2) + 0.005)
    glScalef(0.7, torso_h, 0.03)
    draw_cube(1,1,1)
    glPopMatrix()

    if show_cargo and carrying:
        back_pos = (0.0, 1.1, 0.28)
        glPushMatrix(); glTranslatef(*back_pos); draw_cargo_cube(bombs[entity.carrying_index]); glPopMatrix()

    glPopMatrix()
    glEnable(GL_CULL_FACE)


def is_inside_any_room(x, z):
    centers_x = (-ROOM_SPACING, 0.0, ROOM_SPACING)
    for cx in centers_x:
        if (cx - ROOM_HALF) <= x <= (cx + ROOM_HALF) and (-ROOM_HALF) <= z <= (ROOM_HALF):
            return True
    return False

def aabb_collides_point_aexp(px, pz, aabb, expand):
    cx,cy,cz,sx,sy,sz = aabb
    minx, maxx = cx - sx/2 - expand, cx + sx/2 + expand
    minz, maxz = cz - sz/2 - expand, cz + sz/2 + expand
    return (minx <= px <= maxx) and (minz <= pz <= maxz)

def move_with_collisions(dx, dz):
    new_x = agent.x + dx
    blocked = False
    for w in walls:
        if aabb_collides_point_aexp(new_x, agent.z, w, AGENT_RADIUS):
            blocked = True; break
    if not blocked:
        agent.x = new_x
    new_z = agent.z + dz
    blocked = False
    for w in walls:
        if aabb_collides_point_aexp(agent.x, new_z, w, AGENT_RADIUS):
            blocked = True; break
    if not blocked:
        agent.z = new_z


def reset_game():
    global agent, npc, GAME_OVER, keys_down, bombs
    agent = AgentState()
    agent.z = -3.0

    npc = NPCState()  
    GAME_OVER = False
    keys_down.clear()

    # reset bombs
    bombs = [
        Bomb(x=-ROOM_SPACING, z=0.0, timer=120.0),
        Bomb(x=0.0, z=-1.5, timer=120.0),
        Bomb(x=ROOM_SPACING, z=0.0, timer=120.0),
    ]

def key_callback(window, key, scancode, action, mods):
    global GAME_OVER, agent, bombs

    # --- Handle game over state ---
    if GAME_OVER:
        if action == glfw.PRESS:
            if key == glfw.KEY_ESCAPE:
                glfw.set_window_should_close(window, True)
            elif key == glfw.KEY_R:
                reset_game()
        return

    # --- Key pressed ---
    if action == glfw.PRESS:
        keys_down.add(key)

        if key == glfw.KEY_ESCAPE:
            glfw.set_window_should_close(window, True)

        elif key == glfw.KEY_SPACE:
            # Toggle carry/drop
            if agent.carrying_index is not None:
                # drop it
                idx = agent.carrying_index
                b = bombs[idx]
                fx = math.sin(math.radians(agent.yaw))
                fz = math.cos(math.radians(agent.yaw))
                b.world_pos = (agent.x + fx * 0.6, 0.18, agent.z + fz * 0.6)
                b.carried = False
                agent.carrying_index = None

                # --- Check for bomb deactivation after dropping ---
                cx, _, cz = b.world_pos
                if cargo_in_deactivation_area(cx, cz):
                    b.deactivated = True
                    b.active = False
                    print(f"Bomb {idx} deactivated safely!")
            else:
                # Try to pick up nearest cargo if within range
                best_idx = None
                best_dist = 1e9
                for i, b in enumerate(bombs):
                    if b.deactivated or b.exploded:
                        continue
                    bx, by, bz = b.world_pos
                    dist = math.hypot(agent.x - bx, agent.z - bz)
                    if dist <= PICKUP_RANGE and dist < best_dist:
                        best_dist = dist
                        best_idx = i
                if best_idx is not None:
                    agent.carrying_index = best_idx
                    bombs[best_idx].carried = True

    # --- Key released ---
    elif action == glfw.RELEASE:
        if key in keys_down:
            keys_down.remove(key)


# ------------- Utils -------------
def clamp(v, a, b):
    return max(a, min(b, v))

def process_input(dt):
    moving = False
    yaw = agent.yaw
    if glfw.KEY_A in keys_down or glfw.KEY_LEFT in keys_down:
        yaw += TURN_SPEED * dt
    if glfw.KEY_D in keys_down or glfw.KEY_RIGHT in keys_down:
        yaw -= TURN_SPEED * dt
    agent.yaw = yaw % 360.0

    fx = math.sin(math.radians(agent.yaw))
    fz = math.cos(math.radians(agent.yaw))
    dx = dz = 0.0
    if glfw.KEY_W in keys_down or glfw.KEY_UP in keys_down:
        dx += fx * WALK_SPEED * dt; dz += fz * WALK_SPEED * dt; moving = True
    if glfw.KEY_S in keys_down or glfw.KEY_DOWN in keys_down:
        dx -= fx * WALK_SPEED * dt; dz -= fz * WALK_SPEED * dt; moving = True

    move_with_collisions(dx, dz)
    agent.state = 'walk' if moving else 'idle'

def animate_legs(entity, dt):
    if entity.state == 'walk':
        entity._t += dt
        ang = math.sin(entity._t * LEG_SWING_SPEED) * LEG_SWING_DEG
        entity.leg_l = ang
        entity.leg_r = -ang
    else:
        entity.leg_l += (0 - entity.leg_l) * min(1.0, SMOOTH_RETURN*dt)
        entity.leg_r += (0 - entity.leg_r) * min(1.0, SMOOTH_RETURN*dt)

def find_nearest_path_index(npc_obj):
    best_i = 0
    best_d = 1e9
    for i, (px, pz) in enumerate(npc_obj.path):
        d = math.hypot(px - npc_obj.x, pz - npc_obj.z)
        if d < best_d:
            best_d = d
            best_i = i
    return best_i

def move_towards(npc_obj, tx, tz, dt):
    dx = tx - npc_obj.x
    dz = tz - npc_obj.z
    dist = math.hypot(dx, dz)
    if dist < 0.001:
        return dist
    dir_x = dx / dist
    dir_z = dz / dist
    step = npc_obj.speed * dt
    npc_obj.x += dir_x * step
    npc_obj.z += dir_z * step
    npc_obj.yaw = math.degrees(math.atan2(dir_x, dir_z))
    return dist

def update_npc(npc_obj, dt):
    player_in_room = is_inside_any_room(agent.x, agent.z)
    npc_in_room = is_inside_any_room(npc_obj.x, npc_obj.z)

    if npc_obj.mode == "roam":
        if player_in_room and npc_in_room:
            npc_obj.mode = "chase"
            return update_npc(npc_obj, dt)
        tx, tz = npc_obj.path[npc_obj.current_idx]
        dist = move_towards(npc_obj, tx, tz, dt)
        npc_obj.state = 'walk'
        if dist < 0.15:
            npc_obj.current_idx = (npc_obj.current_idx + 1) % len(npc_obj.path)
            npc_obj.state = 'idle'

    elif npc_obj.mode == "chase":
        if not (player_in_room and npc_in_room):
            npc_obj.mode = "return"
            npc_obj.return_idx = find_nearest_path_index(npc_obj)
            return update_npc(npc_obj, dt)
        dist = move_towards(npc_obj, agent.x, agent.z, dt)
        npc_obj.state = 'walk'

    elif npc_obj.mode == "return":
        tx, tz = npc_obj.path[npc_obj.return_idx]
        dist = move_towards(npc_obj, tx, tz, dt)
        npc_obj.state = 'walk'
        if dist < 0.15:
            npc_obj.current_idx = npc_obj.return_idx
            npc_obj.mode = "roam"
            npc_obj.state = 'idle'

def check_player_npc_collision():
    dx = agent.x - npc.x
    dz = agent.z - npc.z
    dist = math.hypot(dx, dz)
    return dist < 0.7

def draw_game_over_text():
    main_text = "¡Fin del Juego!"
    sub_text = "Presiona R para reiniciar"

    glMatrixMode(GL_PROJECTION)
    glPushMatrix()
    glLoadIdentity()
    gluOrtho2D(0, WIN_W, 0, WIN_H)

    glMatrixMode(GL_MODELVIEW)
    glPushMatrix()
    glLoadIdentity()

    glDisable(GL_LIGHTING)
    glColor3f(1.0, 1.0, 1.0)

    width1 = sum(glutBitmapWidth(GLUT_BITMAP_HELVETICA_18, ord(c)) for c in main_text)
    x1 = (WIN_W - width1) // 2
    y1 = WIN_H // 2 + 12
    glRasterPos2i(x1, y1)
    for ch in main_text:
        glutBitmapCharacter(GLUT_BITMAP_HELVETICA_18, ord(ch))

    width2 = sum(glutBitmapWidth(GLUT_BITMAP_HELVETICA_18, ord(c)) for c in sub_text)
    x2 = (WIN_W - width2) // 2
    y2 = y1 - 28
    glRasterPos2i(x2, y2)
    for ch in sub_text:
        glutBitmapCharacter(GLUT_BITMAP_HELVETICA_18, ord(ch))

    glEnable(GL_LIGHTING)

    glPopMatrix()
    glMatrixMode(GL_PROJECTION)
    glPopMatrix()
    glMatrixMode(GL_MODELVIEW)

def setup_opengl():
    glViewport(0, 0, WIN_W, WIN_H)
    glEnable(GL_DEPTH_TEST)
    glEnable(GL_CULL_FACE); glCullFace(GL_BACK)

    glEnable(GL_LIGHTING); glEnable(GL_LIGHT0)
    glLightfv(GL_LIGHT0, GL_POSITION, (GLfloat * 4)(0.6, 1.0, 0.3, 0.0))
    glLightfv(GL_LIGHT0, GL_DIFFUSE, (GLfloat * 4)(1.0, 1.0, 1.0, 1.0))
    glLightfv(GL_LIGHT0, GL_SPECULAR, (GLfloat * 4)(0.9, 0.9, 0.9, 1.0))
    glLightModelfv(GL_LIGHT_MODEL_AMBIENT, (GLfloat * 4)(0.22,0.22,0.24,1.0))
    glLightModeli(GL_LIGHT_MODEL_TWO_SIDE, GL_TRUE)

    glEnable(GL_NORMALIZE)
    glShadeModel(GL_SMOOTH)
    glClearColor(0.62, 0.70, 0.78, 1.0)

def set_projection():
    glMatrixMode(GL_PROJECTION); glLoadIdentity()
    gluPerspective(60.0, WIN_W/float(WIN_H), 0.1, 500.0)
    glMatrixMode(GL_MODELVIEW)

def set_camera():
    glLoadIdentity()
    ex = agent.x - 12*math.sin(math.radians(agent.yaw))
    ey = 7.5
    ez = agent.z - 12*math.cos(math.radians(agent.yaw))
    cx, cy, cz = agent.x, 1.0, agent.z
    gluLookAt(ex,ey,ez, cx,cy,cz, 0,1,0)

def draw_hud_text(window, text):
    glfw.set_window_title(window, f"M4  |  {text}")

def distance_to_nearest_deactivation(x, z):
    """Return distance from agent to the center of the nearest deactivation area."""
    min_dist = float('inf')
    for area in deactivation_areas:
        cx = (area["x0"] + area["x1"]) / 2
        cz = (area["z0"] + area["z1"]) / 2
        dist = math.hypot(x - cx, z - cz)
        if dist < min_dist:
            min_dist = dist
    return min_dist

def main():
    global GAME_OVER, floor_tex, bombs
    if not glfw.init():
        print("No se pudo inicializar GLFW"); sys.exit(1)
    glfw.window_hint(glfw.SAMPLES, 4)
    window = glfw.create_window(WIN_W, WIN_H, "M4 OpenGL - Animación de Personaje", None, None)
    if not window:
        glfw.terminate(); print("No se pudo crear la ventana"); sys.exit(1)
    glfw.make_context_current(window)
    glfw.set_key_callback(window, key_callback)
    glfw.swap_interval(1)

    glutInit()

    setup_opengl()
    set_projection()
    build_rooms()
    floor_tex = make_checkerboard_tex()

    prev = time.time()
    while not glfw.window_should_close(window):
        now = time.time()
        dt = now - prev; prev = now

        if not GAME_OVER:
            process_input(dt)
            animate_legs(agent, dt)

            update_npc(npc, dt)
            animate_legs(npc, dt)

            if check_player_npc_collision():
                GAME_OVER = True
                agent.state = 'idle'
                npc.state = 'idle'

        # Bomb timers & explosion check (if any bomb explodes, game over)
        for i, b in enumerate(bombs):
            if b.active and not b.deactivated and not b.carried:
                remaining = b.remaining()
                if remaining <= 0 and not b.exploded:
                    b.exploded = True
                    b.active = False
                    print(f"Bomb {i} exploded.")
                    glfw.set_window_title(window, f"GAME OVER — Bomb {i} exploded!")
                    time.sleep(2)
                    glfw.set_window_should_close(window, True)
                    GAME_OVER = True

        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
        set_camera()

        draw_floor(floor_tex)
        draw_room_floors()
        draw_square_areas()
        draw_walls()

        draw_humanoid(
            agent,
            torso_color=(60, 140, 230),
            head_color=(110, 180, 255),
            show_cargo=True,
            carrying=(agent.carrying_index is not None)
        )

        draw_humanoid(
            npc,
            torso_color=(200, 60, 60),
            head_color=(245, 120, 120),
            show_cargo=False,
            carrying=False
        )

        # Draw each bomb's cargo cube if not carried; carried one is drawn on humanoid
        for i, b in enumerate(bombs):
            if b.carried:
                continue
            cx, cy, cz = b.world_pos
            glPushMatrix()
            glTranslatef(cx, cy, cz)
            draw_cargo_cube(b)
            glPopMatrix()

        if not GAME_OVER:
            # Compute HUD info: distance to nearest bomb, and bomb statuses
            nearest_dist = 1e9
            statuses = []
            for i, b in enumerate(bombs):
                bx, by, bz = b.world_pos
                d = math.hypot(agent.x - bx, agent.z - bz)
                if d < nearest_dist:
                    nearest_dist = d
                if b.deactivated:
                    statuses.append(f"[{i}:DEACTIVATED]")
                elif b.exploded:
                    statuses.append(f"[{i}:EXPLODED]")
                else:
                    # show remaining time (if carried we show 'CARRIED')
                    if b.carried:
                        statuses.append(f"[{i}:CARRIED]")
                    else:
                        t = b.remaining()
                        statuses.append(f"[{i}:{t:4.0f}s]")
            dist_deact = distance_to_nearest_deactivation(agent.x, agent.z)
            status = (
                f"Estado:{agent.state.upper()} | Carry:{'ON' if agent.carrying_index is not None else 'OFF'} | "
                f"DistCaja:{nearest_dist:.2f}m | Bombs:{' '.join(statuses)} | Distance{dist_deact:.2f} | Controles: W/S, A/D, Espacio, Esc"
            )
            draw_hud_text(window, status)

        else:
            draw_hud_text(window, "M4 | Juego terminado")
            draw_game_over_text()

        glfw.swap_buffers(window)
        glfw.poll_events()



    glfw.terminate()

if __name__ == "__main__":
    main()
