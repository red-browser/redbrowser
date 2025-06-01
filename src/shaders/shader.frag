#version 460 core
in vec2 TexCoord;
in vec4 Color;

out vec4 FragColor;

uniform sampler2D uTexture;

void main() {
    FragColor = Color * texture(uTexture, TexCoord);
}
