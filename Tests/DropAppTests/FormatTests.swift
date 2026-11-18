import Foundation
import Installer
import Testing

@testable import DropApp

/// The copied-bytes line: one decimal on both numbers, in the total's unit, so its width
/// changes only when the copied number gains a digit.
struct FormatTests {
    private let megabyte: UInt64 = 1_000_000
    private let english = Locale(identifier: "en_US")

    private func line(_ done: UInt64, of total: UInt64, locale: Locale? = nil) -> String {
        Format.progress(InstallProgress(bytesDone: done, bytesTotal: total), locale: locale ?? english)
    }

    @Test func bothNumbersAlwaysShowOneDecimal() {
        let total = 84 * megabyte
        #expect(line(0, of: total) == "0.0 of 84.0 MB")
        #expect(line(9 * megabyte, of: total) == "9.0 of 84.0 MB")
        #expect(line(9_500_000, of: total) == "9.5 of 84.0 MB")
        #expect(line(10 * megabyte, of: total) == "10.0 of 84.0 MB")
        #expect(line(total, of: total) == "84.0 of 84.0 MB")
    }

    @Test func aDecimalPlaceKeepsTheWidth() {
        let total = 84 * megabyte
        let widths = stride(from: 10 * megabyte, through: total, by: Int(megabyte / 7)).map {
            line($0, of: total).count
        }
        #expect(Set(widths) == [15])
    }

    @Test func theCopiedNumberStaysInTheTotalsUnit() {
        #expect(line(840_000, of: 84 * megabyte) == "0.8 of 84.0 MB", "never \"840 of 84 MB\"")
        #expect(line(1_200 * megabyte, of: 12_345 * megabyte) == "1.2 of 12.3 GB")
        #expect(line(250_000, of: 500_000) == "250.0 of 500.0 KB")
    }

    @Test func theCopiedNumberReadsTheTotalOnlyWhenDone() {
        #expect(line(83_990_000, of: 84 * megabyte) == "83.9 of 84.0 MB")
    }

    @Test func aTotalThatRoundsUpToTheNextUnitShowsInIt() {
        #expect(line(0, of: 999_960_000) == "0.0 of 1.0 GB")
        #expect(line(0, of: 999_940_000) == "0.0 of 999.9 MB")
    }

    @Test func theDecimalFollowsTheLocale() {
        #expect(line(9_500_000, of: 84 * megabyte, locale: Locale(identifier: "de_DE")) == "9,5 of 84,0 MB")
    }
}
