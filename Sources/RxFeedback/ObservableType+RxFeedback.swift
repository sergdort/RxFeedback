//
//  ObservableType+Extensions.swift
//  RxFeedback
//
//  Created by Krunoslav Zaher on 4/30/17.
//  Copyright © 2017 Krunoslav Zaher. All rights reserved.
//

import RxSwift
import RxCocoa

extension ObservableType where E == Any {
    /// Feedback loop
    public typealias FeedbackLoop<State, Event> = (ObservableSchedulerContext<State>) -> Observable<Event>

    /**
     System simulation will be started upon subscription and stopped after subscription is disposed.

     System state is represented as a `State` parameter.
     Events are represented by `Event` parameter.

     - parameter initialState: Initial state of the system.
     - parameter accumulator: Calculates new system state from existing state and a transition event (system integrator, reducer).
     - parameter feedback: Feedback loops that produce events depending on current system state.
     - returns: Current state of the system.
     */
    public static func system<State, Event>(
            initialState: State,
            reduce: @escaping (State, Event) -> State,
            scheduler: ImmediateSchedulerType,
            scheduledFeedback: [FeedbackLoop<State, Event>]
        ) -> Observable<State> {
        return Observable<State>.deferred {
            let replaySubject = ReplaySubject<State>.create(bufferSize: 1)

            let asyncScheduler = scheduler.async
            
            let events: Observable<Event> = Observable.merge(scheduledFeedback.map { feedback in
                let state = ObservableSchedulerContext(source: replaySubject.asObservable(), scheduler: asyncScheduler)
                let events = feedback(state)
                return events
                    // This is protection from accidental ignoring of scheduler so
                    // reentracy errors can be avoided
                    .observeOn(CurrentThreadScheduler.instance)
            })

            return events.scan(initialState, accumulator: reduce)
                .do(onNext: { output in
                    replaySubject.onNext(output)
                }, onSubscribed: {
                    replaySubject.onNext(initialState)
                })
                .subscribeOn(scheduler)
                .startWith(initialState)
                .observeOn(scheduler)
        }
    }

    public static func system<State, Event>(
            initialState: State,
            reduce: @escaping (State, Event) -> State,
            scheduler: ImmediateSchedulerType,
            scheduledFeedback: FeedbackLoop<State, Event>...
        ) -> Observable<State> {
        return system(initialState: initialState, reduce: reduce, scheduler: scheduler, scheduledFeedback: scheduledFeedback)
    }
    
    public static func sustemV2<State, Event>(
        initialState: State,
        reduce: @escaping (State, Event) -> State,
        scheduler: ImmediateSchedulerType,
        scheduledFeedback: [FeedbackLoopV2<State, Event>]
        ) -> Observable<State> {
        let replaySubject = ReplaySubject<State>.create(bufferSize: 1)
        
        let asyncScheduler = scheduler.async
        
        let events: Observable<Event> = Observable.merge(scheduledFeedback.map { feedback in
            return feedback.loop(asyncScheduler, replaySubject.asObservable())
        })
        
        return events.scan(initialState, accumulator: reduce)
            .do(onNext: { output in
                replaySubject.onNext(output)
            }, onSubscribed: {
                replaySubject.onNext(initialState)
            })
            .subscribeOn(scheduler)
            .startWith(initialState)
            .observeOn(scheduler)
    }
}

extension SharedSequenceConvertibleType where E == Any {
    /// Feedback loop
    public typealias FeedbackLoop<State, Event> = (SharedSequence<SharingStrategy, State>) -> SharedSequence<SharingStrategy, Event>

    /**
     System simulation will be started upon subscription and stopped after subscription is disposed.

     System state is represented as a `State` parameter.
     Events are represented by `Event` parameter.

     - parameter initialState: Initial state of the system.
     - parameter accumulator: Calculates new system state from existing state and a transition event (system integrator, reducer).
     - parameter feedback: Feedback loops that produce events depending on current system state.
     - returns: Current state of the system.
     */
    public static func system<State, Event>(
            initialState: State,
            reduce: @escaping (State, Event) -> State,
            feedback: [FeedbackLoop<State, Event>]
        ) -> SharedSequence<SharingStrategy, State> {

        let observableFeedbacks: [(ObservableSchedulerContext<State>) -> Observable<Event>] = feedback.map { feedback in
            return { sharedSequence in
                return feedback(sharedSequence.source.asSharedSequence(onErrorDriveWith: .empty()))
                    .asObservable()
            }
        }
        
        return Observable<Any>.system(
                initialState: initialState,
                reduce: reduce,
                scheduler: SharingStrategy.scheduler,
                scheduledFeedback: observableFeedbacks
            )
            .asSharedSequence(onErrorDriveWith: .empty())
    }

    public static func system<State, Event>(
            initialState: State,
            reduce: @escaping (State, Event) -> State,
            feedback: FeedbackLoop<State, Event>...
        ) -> SharedSequence<SharingStrategy, State> {
        return system(initialState: initialState, reduce: reduce, feedback: feedback)
    }
}

extension ImmediateSchedulerType {
    var async: ImmediateSchedulerType {
        // This is a hack because of reentrancy. We need to make sure events are being sent async.
        // In case MainScheduler is being used MainScheduler.asyncInstance is used to make sure state is modified async.
        // If there is some unknown scheduler instance (like TestScheduler), just use it.
        return (self as? MainScheduler).map { _ in MainScheduler.asyncInstance } ?? self
    }
}


/// Tuple of observable sequence and corresponding scheduler context on which that observable
/// sequence receives elements.
public struct ObservableSchedulerContext<Element>: ObservableType {
    public typealias E = Element

    /// Source observable sequence
    public let source: Observable<Element>

    /// Scheduler on which observable sequence receives elements
    public let scheduler: ImmediateSchedulerType

    /// Initializes self with source observable sequence and scheduler
    ///
    /// - parameter source: Source observable sequence.
    /// - parameter scheduler: Scheduler on which source observable sequence receives elements.
    public init(source: Observable<Element>, scheduler: ImmediateSchedulerType) {
        self.source = source
        self.scheduler = scheduler
    }

    public func subscribe<O: ObserverType>(_ observer: O) -> Disposable where O.E == E {
        return self.source.subscribe(observer)
    }
}

public struct FeedbackLoopV2<State, Event> {
    let loop: (ImmediateSchedulerType, Observable<State>) -> Observable<Event>
    
    public init<Control: Equatable>(query: @escaping (State) -> Control?, effects: @escaping (Control) -> Observable<Event>) {
        self.loop = { scheduler, state -> Observable<Event> in
            return state.map(query)
                .distinctUntilChanged { $0 == $1 }
                .flatMapLatest { control -> Observable<Event> in
                    guard let control = control else { return Observable.empty() }
                    
                    return effects(control).enqueue(scheduler)
                }
        }
    }
    
    public init(predicate: @escaping (State) -> Bool, effects: @escaping (State) -> Observable<Event>) {
        self.loop = { scheduler, state -> Observable<Event> in
            return state.flatMapLatest { state -> Observable<Event> in
                guard predicate(state) else { return Observable.empty() }
                
                return effects(state).enqueue(scheduler)
            }
        }
    }
    
    public init(effects: @escaping (State) -> Observable<Event>) {
        self.loop = { scheduler, state in
            return state.flatMapLatest { state in
                return effects(state).enqueue(scheduler)
            }
        }
    }
}
