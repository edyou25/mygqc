#!/usr/bin/env python3
"""
TowerOptimize Log Node Visualizer - Simple Version
Extract A* search nodes from log files and visualize directly
"""

import sys
import re
import matplotlib

# Try interactive backends, fallback to non-interactive
interactive_mode = False
try:
    matplotlib.use('TkAgg')
    import tkinter as tk
    print("Using TkAgg backend for interactive display")
    interactive_mode = True
except:
    try:
        matplotlib.use('Qt5Agg')
        print("Using Qt5Agg backend for interactive display")
        interactive_mode = True
    except:
        print("No GUI backend available, using non-interactive mode")
        matplotlib.use('Agg')
        interactive_mode = False

import matplotlib.pyplot as plt

def parse_log_file(log_path):
    """Parse log file and extract node information"""
    nodes = []
    path_nodes = []
    visual_path_nodes = []

    try:
        with open(log_path, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                
                # Extract current node information
                current_node_match = re.search(r'Current node: lat=([\d\.]+), lon=([\d\.]+), cost=([\d\.]+), parent=(-?\d+)', line)
                if current_node_match:
                    lat, lon, cost, parent = current_node_match.groups()
                    nodes.append({
                        'lat': float(lat),
                        'lon': float(lon),
                        'cost': float(cost),
                        'parent': int(parent),
                        'type': 'current',
                        'line': line_num
                    })
                
                # Extract candidate node information
                candidate_node_match = re.search(r'Candidate node: lat=([\d\.]+), lon=([\d\.]+), cost=([\d\.]+), parent=(-?\d+)', line)
                if candidate_node_match:
                    lat, lon, cost, parent = candidate_node_match.groups()
                    nodes.append({
                        'lat': float(lat),
                        'lon': float(lon),
                        'cost': float(cost),
                        'parent': int(parent),
                        'type': 'candidate',
                        'line': line_num
                    })

                # Extract visualized path node information (new format)
                # Format: 'Path node: lat=22.70273650, lon=114.38295602'
                pathnode_match = re.search(r'Path node: lat=([\d\.]+), lon=([\d\.]+)', line)
                if pathnode_match:
                    lat, lon = pathnode_match.groups()
                    visual_path_nodes.append({
                        'lat': float(lat),
                        'lon': float(lon),
                        'alt': None,  # No altitude info
                        'type': 'visualpathnode',
                        'line': line_num
                    })
                
                # Extract waypoint information
                waypoint_match = re.search(r'Waypoint \d+ lat: ([\d\.]+) lon: ([\d\.]+) alt: ([\d\.NaN]+)', line)
                if waypoint_match:
                    lat, lon, alt = waypoint_match.groups()
                    waypoint_data = {
                        'lat': float(lat),
                        'lon': float(lon),
                        'type': 'waypoint',
                        'line': line_num
                    }
                    try:
                        waypoint_data['alt'] = float(alt) if alt != 'NaN' else None
                    except:
                        waypoint_data['alt'] = None
                    path_nodes.append(waypoint_data)
                
                # Extract old format path points (for backward compatibility)
                old_waypoint_match = re.search(r'Updated waypoint \d+ to ([\d\.]+) ([\d\.]+)', line)
                if old_waypoint_match:
                    lat, lon = old_waypoint_match.groups()
                    path_nodes.append({
                        'lat': float(lat),
                        'lon': float(lon),
                        'alt': None,
                        'type': 'waypoint_old',
                        'line': line_num
                    })

    except FileNotFoundError:
        print(f"Error: Log file not found {log_path}")
        return [], [], []
    except Exception as e:
        print(f"Error reading log file: {e}")
        return [], [], []
    
    return nodes, path_nodes, visual_path_nodes

def parse_coordinate(coord_str):
    """Parse coordinate string to decimal degrees"""
    try:
        coord_str = coord_str.replace('"', '').replace('°', ' ').replace('\'', ' ').strip()
        parts = coord_str.split()
        if len(parts) < 4:
            return None
            
        degrees = float(parts[0])
        minutes = float(parts[1])
        seconds = float(parts[2])
        direction = parts[3]
        
        decimal = degrees + minutes/60.0 + seconds/3600.0
        
        if direction in ['S', 'W']:
            decimal = -decimal
            
        return decimal
    except:
        return None

def visualize_nodes(nodes, path_nodes, visual_path_nodes, log_path):
    """Visualize nodes in a window"""
    if not nodes and not path_nodes and not visual_path_nodes:
        print("No node data found")
        return
    
    plt.figure(figsize=(12, 8))
    
    # Plot A* nodes
    if nodes:
        current_nodes = [n for n in nodes if n['type'] == 'current']
        candidate_nodes = [n for n in nodes if n['type'] == 'candidate']
        
        if current_nodes:
            # current_nodes = current_nodes[:7]
            current_lats = [n['lat'] for n in current_nodes]
            current_lons = [n['lon'] for n in current_nodes]
            plt.scatter(current_lons, current_lats, c='blue', s=200, alpha=0.8, label=f'Current Nodes ({len(current_nodes)})')
        
        if candidate_nodes:
            candidate_lats = [n['lat'] for n in candidate_nodes]
            candidate_lons = [n['lon'] for n in candidate_nodes]
            plt.scatter(candidate_lons, candidate_lats, c='lightblue', s=30, alpha=0.6, label=f'Candidate Nodes ({len(candidate_nodes)})')
    
    # Plot path nodes (original formats)
    if path_nodes:
        new_waypoints = [n for n in path_nodes if n['type'] == 'waypoint']
        old_waypoints = [n for n in path_nodes if n['type'] == 'waypoint_old']
        
        if new_waypoints:
            new_lats = [n['lat'] for n in new_waypoints]
            new_lons = [n['lon'] for n in new_waypoints]
            plt.plot(new_lons, new_lats, 'r-', linewidth=2, marker='o', markersize=8, label=f'Waypoints ({len(new_waypoints)})')
            # Mark start and end points
            if len(new_waypoints) >= 2:
                plt.scatter(new_lons[0], new_lats[0], c='green', s=100, marker='s', label='Start Point')
                plt.scatter(new_lons[-1], new_lats[-1], c='red', s=100, marker='s', label='End Point')
        
        if old_waypoints:
            old_lats = [n['lat'] for n in old_waypoints]
            old_lons = [n['lon'] for n in old_waypoints]
            plt.plot(old_lons, old_lats, 'orange', linewidth=2, marker='s', markersize=6, label=f'Old Format Path ({len(old_waypoints)})')

    # # Plot visualized Path node (Path node: ...)
    if visual_path_nodes:
        visual_lats = [n['lat'] for n in visual_path_nodes]
        visual_lons = [n['lon'] for n in visual_path_nodes]
        plt.plot(visual_lons, visual_lats, color='#13b400', linestyle='-', linewidth=2, marker='D',
                 markersize=7, label=f'Path Nodes ({len(visual_path_nodes)})')
        # Mark start/end for visual pathnodes
        if len(visual_path_nodes) >= 2:
            plt.scatter(visual_lons[0], visual_lats[0], c='#008000', s=120, marker='P', label='Path Start')
            plt.scatter(visual_lons[-1], visual_lats[-1], c='#b40013', s=120, marker='P', label='Path End')

    plt.xlabel('Longitude')
    plt.ylabel('Latitude')
    plt.title(f'A* Search Nodes - {log_path.split("/")[-1]}')
    plt.legend()
    plt.grid(True, alpha=0.3)
    
    plt.gca().xaxis.set_major_formatter(plt.FuncFormatter(lambda x, p: f'{x:.6f}°'))
    plt.gca().yaxis.set_major_formatter(plt.FuncFormatter(lambda x, p: f'{x:.6f}°'))
    
    plt.tight_layout()
    
    # Print statistics
    print(f"\n=== Node Statistics ===")
    print(f"Current nodes: {len([n for n in nodes if n['type'] == 'current'])}")
    print(f"Candidate nodes: {len([n for n in nodes if n['type'] == 'candidate'])}")
    # Separate waypoint statistics
    new_waypoints = [n for n in path_nodes if n['type'] == 'waypoint']
    old_waypoints = [n for n in path_nodes if n['type'] == 'waypoint_old']
    print(f"New format waypoints: {len(new_waypoints)}")
    print(f"Old format waypoints: {len(old_waypoints)}")
    print(f"Visualized path nodes: {len(visual_path_nodes)}")
    print(f"Total waypoints: {len(path_nodes)}")
    print(f"Total nodes: {len(nodes) + len(path_nodes) + len(visual_path_nodes)}")
    
    # Show visual path node details
    if visual_path_nodes:
        print(f"\n=== Visualized Path Node Details ===")
        for i, n in enumerate(visual_path_nodes):
            print(f"Path node {i}: lat={n['lat']:.8f}, lon={n['lon']:.8f}")
    # Show waypoint details if available
    if new_waypoints:
        print(f"\n=== Waypoint Details ===")
        for i, wp in enumerate(new_waypoints):
            alt_str = f"{wp['alt']:.2f}" if wp['alt'] is not None else "NaN"
            print(f"Waypoint {i}: lat={wp['lat']:.8f}, lon={wp['lon']:.8f}, alt={alt_str}")
    
    print("\nOpening interactive visualization window...")
    print("Close the window to continue.")
    plt.show()

def main():
    if len(sys.argv) != 2:
        print("Usage: python plot.py <log_file_path>")
        print("Example: python plot.py /workspace/build_new/log/20251026_121624.log")
        sys.exit(1)
    
    log_path = sys.argv[1]
    print(f"Parsing log file: {log_path}")
    
    nodes, path_nodes, visual_path_nodes = parse_log_file(log_path)
    visualize_nodes(nodes, path_nodes, visual_path_nodes, log_path)

if __name__ == "__main__":
    main()