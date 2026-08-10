import XCTest
@testable import PhotoDropMac

/// A mounted disk image is `local`, `ejectable` **and** `removable` — the exact
/// signature `DriveWatcher` uses to recognise a card — so the only thing that
/// separates the two is how the media is backed. These fixtures are real
/// `DADiskCopyDescription` dictionaries captured on macOS from mounted volumes.
final class VolumeBackingTests: XCTestCase {

    /// Read/write `.dmg` (HFS+), read-only compressed `.dmg` (UDZO), APFS
    /// `.dmg`, and a `.sparsebundle` all describe themselves identically.
    private func diskImageDescription(unit: String) -> [String: Any] {
        [
            "DADeviceModel": "Disk Image",
            "DADeviceProtocol": "Virtual Interface",
            "DADeviceVendor": "Apple",
            "DADevicePath": "IOService:/IOResources/IOHDIXController/IOHDIXHDDriveOutKernel@\(unit)/IODiskImageBlockStorageDeviceOutKernel",
            "DAMediaEjectable": 1,
            "DAMediaRemovable": 1,
        ]
    }

    func testMountedDiskImageIsRecognised() {
        for unit in ["7", "8", "a", "b"] {
            XCTAssertTrue(
                VolumeBacking.isDiskImage(diskImageDescription(unit: unit)),
                "a mounted .dmg must never be offered as a card"
            )
        }
    }

    func testDiskImageRecognisedFromModelAlone() {
        XCTAssertTrue(VolumeBacking.isDiskImage(["DADeviceModel": "Disk Image"]))
    }

    func testDiskImageRecognisedFromDevicePathAlone() {
        // The structural signal: the media is served by the kernel's disk-image
        // controller, whatever the vendor strings happen to say.
        XCTAssertTrue(VolumeBacking.isDiskImage([
            "DADevicePath": "IOService:/IOResources/IOHDIXController/IOHDIXHDDriveOutKernel@3/IODiskImageBlockStorageDeviceOutKernel",
        ]))
    }

    func testUSBCardReaderIsNotADiskImage() {
        XCTAssertFalse(VolumeBacking.isDiskImage([
            "DADeviceModel": "SD/MMC Reader",
            "DADeviceProtocol": "USB",
            "DADeviceVendor": "Generic",
            "DADevicePath": "IOService:/AppleARMPE/arm-io@10F00000/AppleT8122USBXHCI@01000000/usb-drd0@01000000/AppleUSBXHCIPort@01100000/USB2.0 Hub@01100000/AppleUSB20Hub@01100000/AppleUSB20HubPort@01110000/SD/MMC Reader@01110000/IOUSBHostInterface@0/IOUSBMassStorageInterfaceNub/IOUSBMassStorageDriverNub/IOUSBMassStorageDriver/IOSCSIPeripheralDeviceNub/IOSCSIPeripheralDeviceType00",
        ]))
    }

    func testBuiltInSDReaderIsNotADiskImage() {
        XCTAssertFalse(VolumeBacking.isDiskImage([
            "DADeviceModel": "APPLE SD Card Reader",
            "DADeviceProtocol": "Secure Digital",
            "DADeviceVendor": "APPLE",
            "DADevicePath": "IOService:/AppleARMPE/arm-io@10F00000/apcie@90000000/AppleT8122PCIeCMacBridge/pci-bridge0@0/AppleT8122PCIeCMacPort/pci-bridge2@2/AppleSDXCController/AppleSDXCMediaSlot",
        ]))
    }

    func testInternalDiskIsNotADiskImage() {
        XCTAssertFalse(VolumeBacking.isDiskImage([
            "DADeviceModel": "APPLE SSD AP0512Z",
            "DADeviceProtocol": "Apple Fabric",
            "DADevicePath": "IOService:/AppleARMPE/arm-io@10F00000/AppleH15IO/ans@79400000/AppleASCWrapV6/iop-ans-nub/RTBuddy(ANS2)/RTBuddyService/AppleANS3CGv2Controller/NS_01@1",
        ]))
    }

    /// Fail open: a description we could not read is not evidence of a disk
    /// image. Hiding a real card is worse than listing a stray `.dmg`.
    func testEmptyDescriptionIsNotADiskImage() {
        XCTAssertFalse(VolumeBacking.isDiskImage([:]))
    }
}
