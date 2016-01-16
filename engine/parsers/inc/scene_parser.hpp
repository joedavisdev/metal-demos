#pragma once
#include <string>
#include <vector>
#include "glm/glm.hpp"
#include "json/json.h"
#include "glm/glm.hpp"

namespace JMD {
    struct ParsedEffect {
        std::string name;
        std::vector<std::string> uniform_block_names;
        std::string vert_shader_name;
        std::string frag_shader_name;
    };
    struct ParsedActor {
        std::string name;
        std::vector<std::string> attribute_block_names;
        std::string effect_name;
        std::string model_name;
        glm::vec4   world_position;
    };
    struct ParsedRenderPass {
        std::string name;
        std::string actor_regex;
        std::vector<std::string> colour_formats;
        std::string depth_stencil_formats;
    };
class SceneParser {
public:
    void Parse(const std::string &scene_file);
    std::vector<ParsedEffect> effects;
    std::vector<ParsedActor> actors;
    std::vector<ParsedRenderPass> render_passes;
private:
    void ProcessEffects(const Json::Value &effects_node);
    void ProcessActors(const Json::Value &actors_node);
    void ProcessRenderPasses(const Json::Value &render_pass_node);
};
} // namespace JMD