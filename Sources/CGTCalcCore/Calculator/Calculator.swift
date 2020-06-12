//
//  Calculator.swift
//  cgtcalc
//
//  Created by Matt Galloway on 06/06/2020.
//

import Foundation

public class Calculator {
  private let input: CalculatorInput
  private let logger: Logger

  public init(input: CalculatorInput, logger: Logger) throws {
    self.input = input
    self.logger = logger
  }

  public func process() throws -> CalculatorResult {
    self.logger.info("Begin processing")
    try self.preprocessTransactions()
    let calculatorResult = try self.processTransactions()
    self.logger.info("Finished processing")
    return calculatorResult
  }

  private func preprocessTransactions() throws {
    for transaction in self.input.transactions {
      // 6th April 2008 is when new CGT rules came in. We only support those new rules.
      if transaction.date < Date(timeIntervalSince1970: 1207440000) {
        throw CalculatorError.TransactionDateNotSupported
      }
    }
  }

  private func processTransactions() throws -> CalculatorResult {
    let transactionsByAsset = self.input.transactions
      .reduce(into: [String:[Transaction]]()) { (result, transaction) in
        var transactions = result[transaction.asset, default: []]
        transactions.append(transaction)
        result[transaction.asset] = transactions
      }
    let assetEventsByAsset = self.input.assetEvents
      .reduce(into: [String:[AssetEvent]]()) { (result, assetEvent) in
        var assetEvents = result[assetEvent.asset, default: []]
        assetEvents.append(assetEvent)
        result[assetEvent.asset] = assetEvents
      }

    let allDisposalMatches = try transactionsByAsset
      .map { (asset, transactions) -> AssetResult in
        let sortedTransactions = transactions.sorted { $0.date < $1.date }
        var acquisitions: [SubTransaction] = []
        var disposals: [SubTransaction] = []
        sortedTransactions.forEach { transaction in
          let subTransaction = SubTransaction(transaction: transaction)
          switch transaction.kind {
          case .Buy:
            acquisitions.append(subTransaction)
          case .Sell:
            disposals.append(subTransaction)
          }
        }
        let assetEvents = assetEventsByAsset[asset, default: []].sorted { $0.date < $1.date }
        let state = AssetProcessorState(asset: asset, acquisitions: acquisitions, disposals: disposals, assetEvents: assetEvents)
        return try processAsset(withState: state)
      }
      .reduce(into: [DisposalMatch]()) { (disposalMatches, assetResult) in
        disposalMatches.append(contentsOf: assetResult.disposalMatches)
      }

    return try CalculatorResult(input: self.input, disposalMatches: allDisposalMatches)
  }

  private func processAsset(withState state: AssetProcessorState) throws -> AssetResult {
    self.logger.info("Begin processing transactions for \(state.asset).")

    let sameDayProcessor = MatchingProcessor(state: state, logger: self.logger) { (acquisition, disposal) in
      if acquisition.date < disposal.date {
        return .SkipAcquisition
      } else if disposal.date < acquisition.date {
        return .SkipDisposal
      } else {
        return .Match(DisposalMatch(kind: .SameDay(acquisition), disposal: disposal))
      }
    }
    try sameDayProcessor.process()

    let bedAndBreakfastProcessor = MatchingProcessor(state: state, logger: self.logger) { (acquisition, disposal) in
      if acquisition.date < disposal.date {
        return .SkipAcquisition
      } else if disposal.date.addingTimeInterval(60*60*24*30) < acquisition.date {
        return .SkipDisposal
      } else {
        return .Match(DisposalMatch(kind: .BedAndBreakfast(acquisition), disposal: disposal))
      }
    }
    try bedAndBreakfastProcessor.process()

    let section104Processor = Section104Processor(state: state, logger: self.logger)
    try section104Processor.process()

    if !state.isComplete {
      throw CalculatorError.Incomplete
    }

    self.logger.debug("Tax events for \(state.asset)")
    state.disposalMatches.forEach { self.logger.debug("  \($0)") }
    self.logger.info("Finished processing transactions for \(state.asset). Created \(state.disposalMatches.count) tax events.")

    return AssetResult(asset: state.asset, disposalMatches: state.disposalMatches)
  }
}
