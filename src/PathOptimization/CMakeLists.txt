find_package(Qt5 REQUIRED COMPONENTS Core Positioning Gui)

set(PathOptimization_SOURCES
    TowerOptimizer.cc
    PathOptimizationManager.cc

)

set(PathOptimization_HEADERS
    TowerOptimizer.h
    PathOptimizationManager.h

)

add_library(PathOptimization STATIC
    ${PathOptimization_SOURCES}
    ${PathOptimization_HEADERS}
)

target_link_libraries(PathOptimization
    PUBLIC
        Qt5::Core
        Qt5::Positioning
        Qt5::Gui
)

target_include_directories(PathOptimization PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

