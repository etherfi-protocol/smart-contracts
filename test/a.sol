pragma solidity ^0.8.13;

contract StorageOptimizedQueueLIFO {
  struct Slot {
    uint32[8] elems;
  }

  Slot[] private _container;
  uint256 private _length;

  function push(uint32 _element) external {
    uint256 slotIndex = _length / 8;
    uint256 positionWithinSlot = _length % 8;

    if (positionWithinSlot == 0) {
      _container.push();
    }
    _container[slotIndex].elems[positionWithinSlot] = _element;  
  }
  
  function pop() external returns (uint32 _element) {
    _length -= 1;
    uint256 slotIndex = _length / 8;
    uint256 positionWithinSlot = _length % 8;
    _element = _container[slotIndex].elems[positionWithinSlot];
  }
  
  function length() external view returns (uint256) {
    return _length;
  }
}