# PS5 Arabic Translator Plugin (etaHEN 5.50 / ps5-payload-dev SDK)

PS5_PAYLOAD_SDK ?= /opt/ps5-payload-sdk
CXX             ?= $(PS5_PAYLOAD_SDK)/bin/prospero-clang++

TARGET          := ps5_translator.plugin
SRCS            := \
	src/plugin_main.cpp \
	src/config_manager.cpp \
	src/input_controller.cpp \
	src/network_client.cpp \
	src/roi_capture_and_diff.cpp \
	src/overlay/arabic_font_atlas.cpp \
	src/overlay/overlay_renderer.cpp

OBJS            := $(SRCS:.cpp=.o)

CXXFLAGS        := -O2 -std=c++17 -fPIC -Wall -Wextra -Wno-unused-parameter \
                   -Isrc -Isrc/overlay -I../shared-protocol
LDFLAGS         := -shared -lpthread -lm

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS)

src/%.o: src/%.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)
