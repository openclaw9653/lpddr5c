#!/bin/bash
#============================================================================
# LPDDR5 Controller Simulation Script
#============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

# Default configuration
SIMULATOR=${SIMULATOR:-vcs}
WAVES=${WAVES:-1}
TEST=${TEST:-all}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#============================================================================
# Functions
#============================================================================

print_header() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}"
}

print_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

print_success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

check_tool() {
    if ! command -v "$1" &> /dev/null; then
        print_error "$1 not found!"
        return 1
    fi
    return 0
}

#============================================================================
# Main Script
#============================================================================

cd "$PROJ_DIR"

echo ""
print_header "LPDDR5 Controller Simulation Flow"
echo ""
echo "Project:    $PROJ_DIR"
echo "Simulator:  $SIMULATOR"
echo "Waves:      $WAVES"
echo "Test:       $TEST"
echo ""

# Check if Makefile exists
if [ ! -f "sim/Makefile" ]; then
    print_error "sim/Makefile not found!"
    exit 1
fi

# Run simulation
case "$1" in
    help|--help|-h)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  help        - Show this help"
        echo "  vcs         - Run with VCS"
        echo "  xcelium     - Run with Xcelium"
        echo "  verilator   - Run with Verilator"
        echo "  comp        - Compile only"
        echo "  sim         - Simulate only"
        echo "  waves       - View waveforms"
        echo "  clean       - Clean simulation files"
        echo ""
        echo "Environment Variables:"
        echo "  SIMULATOR=vcs|xcelium|verilator  - Select simulator"
        echo "  WAVES=0|1                         - Enable waveform dump"
        echo ""
        ;;

    vcs)
        SIMULATOR=vcs make -C sim vcs
        ;;

    xcelium)
        SIMULATOR=xcelium make -C sim xcelium
        ;;

    verilator)
        SIMULATOR=verilator make -C sim verilator
        ;;

    comp|compile)
        SIMULATOR=$SIMULATOR make -C sim comp
        ;;

    sim|simulate)
        SIMULATOR=$SIMULATOR make -C sim sim
        ;;

    waves|view)
        make -C sim waves
        ;;

    clean)
        make -C sim clean
        ;;

    *)
        # Default: run with selected simulator
        if [ -n "$1" ]; then
            print_error "Unknown command: $1"
            echo "Use '$0 help' for usage"
            exit 1
        fi
        
        # Run with default simulator
        case "$SIMULATOR" in
            vcs)
                make -C sim vcs
                ;;
            xcelium)
                make -C sim xcelium
                ;;
            verilator)
                make -C sim verilator
                ;;
            *)
                print_error "Unknown simulator: $SIMULATOR"
                echo "Use SIMULATOR=vcs|xcelium|verilator"
                exit 1
                ;;
        esac
        ;;
esac

# Check result
if [ $? -eq 0 ]; then
    print_success "Simulation flow completed!"
else
    print_error "Simulation flow failed!"
    exit 1
fi
