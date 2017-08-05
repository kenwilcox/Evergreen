//
//  StatusesTable.swift
//  Evergreen
//
//  Created by Brent Simmons on 5/8/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSDatabase
import Data

final class StatusesTable: DatabaseTable {

	let name: String
	let queue: RSDatabaseQueue
	private let cache = ObjectCache<ArticleStatus>(keyPathForID: \ArticleStatus.articleID)

	init(name: String, queue: RSDatabaseQueue) {

		self.name = name
		self.queue = queue
	}

	func markArticles(_ articles: Set<Article>, statusKey: String, flag: Bool) {

		// Main thread.

		assertNoMissingStatuses(articles)
		let statuses = Set(articles.flatMap { $0.status })
		markArticleStatuses(statuses, statusKey: statusKey, flag: flag)
	}

	func attachStatuses(_ articles: Set<Article>, _ database: FMDatabase) {

		// Look in cache first.
		attachCachedStatuses(articles)
		let articlesNeedingStatuses = articlesMissingStatuses(articles)
		if articlesNeedingStatuses.isEmpty {
			return
		}

		// Fetch from database.
		fetchAndCacheStatusesForArticles(articlesNeedingStatuses, database)
		attachCachedStatuses(articlesNeedingStatuses)

		// Create new statuses, and cache and save them in the database.
		// It shouldn’t happen that an Article in the database has no corresponding ArticleStatus,
		// but the case should be handled anyway.

		let articlesNeedingStatusesCreated = articlesMissingStatuses(articlesNeedingStatuses)
		if articlesNeedingStatusesCreated.isEmpty {
			return
		}
		createAndSaveStatusesForArticles(articlesNeedingStatusesCreated, database)

		assertNoMissingStatuses(articles)
	}


//	func ensureStatusesForParsedArticles(_ parsedArticles: [ParsedItem], _ callback: @escaping RSVoidCompletionBlock) {
//
//		// 1. Check cache for statuses
//		// 2. Fetch statuses not found in cache
//		// 3. Create, save, and cache statuses not found in database
//
//		var articleIDs = Set(parsedArticles.map { $0.articleID })
//		articleIDs = articleIDsMissingStatuses(articleIDs)
//		if articleIDs.isEmpty {
//			callback()
//			return
//		}
//
//		queue.fetch { (database: FMDatabase!) -> Void in
//
//			let statuses = self.fetchStatusesForArticleIDs(articleIDs, database: database)
//
//			DispatchQueue.main.async {
//
//				self.cache.addObjectsNotCached(Array(statuses))
//
//				let newArticleIDs = self.articleIDsMissingStatuses(articleIDs)
//				if !newArticleIDs.isEmpty {
//					self.createAndSaveStatusesForArticleIDs(newArticleIDs)
//				}
//
//				callback()
//			}
//		}
//	}
}

private extension StatusesTable {
	
	func attachCachedStatuses(_ articles: Set<Article>) {

		articles.forEach { (oneArticle) in

			if let cachedStatus = cache[oneArticle.databaseID] {
				oneArticle.status = cachedStatus
			}
		}
	}

	func assertNoMissingStatuses(_ articles: Set<Article>) {

		for oneArticle in articles {
			if oneArticle.status == nil {
				assertionFailure("All articles must have a status at this point.")
				return
			}
		}
	}

	// MARK: Fetching

	func fetchAndCacheStatusesForArticles(_ articles: Set<Article>, _ database: FMDatabase) {

		fetchAndCacheStatusesForArticleIDs(articleIDsFromArticles(articles), database)
	}

	func fetchAndCacheStatusesForArticleIDs(_ articleIDs: Set<String>, _ database: FMDatabase) {

		let statuses = fetchStatusesForArticleIDs(articleIDs, database)
		cache.addObjectsNotCached(Array(statuses))
	}

	func fetchStatusesForArticleIDs(_ articleIDs: Set<String>, _ database: FMDatabase) -> Set<ArticleStatus> {
		
		if !articleIDs.isEmpty, let resultSet = selectRowsWhere(key: DatabaseKey.articleID, inValues: Array(articleIDs), in: database) {
			return articleStatusesWithResultSet(resultSet)
		}
		
		return Set<ArticleStatus>()
	}

	func articleStatusesWithResultSet(_ resultSet: FMResultSet) -> Set<ArticleStatus> {
		
		var statuses = Set<ArticleStatus>()
		
		while(resultSet.next()) {
			if let oneArticleStatus = ArticleStatus(row: resultSet) {
				statuses.insert(oneArticleStatus)
			}
		}
		
		return statuses
	}
	
	// MARK: Updating
	
	func markArticleStatuses(_ statuses: Set<ArticleStatus>, statusKey: String, flag: Bool) {

		// Ignore the statuses where status.[statusKey] == flag. Update the remainder and save in database.

		var articleIDsToUpdate = Set<String>()

		statuses.forEach { (oneStatus) in

			if oneStatus.boolStatus(forKey: statusKey) == flag {
				return
			}

			oneStatus.setBoolStatus(flag, forKey: statusKey)
			articleIDsToUpdate.insert(oneStatus.articleID)
		}

		if !articleIDsToUpdate.isEmpty {
			updateArticleStatusesInDatabase(articleIDsToUpdate, statusKey: statusKey, flag: flag)
		}
	}

	private func updateArticleStatusesInDatabase(_ articleIDs: Set<String>, statusKey: String, flag: Bool) {

		updateRowsWithValue(NSNumber(value: flag), valueKey: statusKey, whereKey: DatabaseKey.articleID, matches: Array(articleIDs))
	}
	
	// MARK: Creating

	func saveStatuses(_ statuses: Set<ArticleStatus>, _ database: FMDatabase) {

		let statusArray = statuses.map { $0.databaseDictionary() }
		insertRows(statusArray, insertType: .orIgnore, in: database)
	}

	func createAndSaveStatusesForArticles(_ articles: Set<Article>, _ database: FMDatabase) {

		let articleIDs = Set(articles.map { $0.databaseID })
		createAndSaveStatusesForArticleIDs(articleIDs, database)
	}

	func createAndSaveStatusesForArticleIDs(_ articleIDs: Set<String>, _ database: FMDatabase) {

		let now = Date()
		let statuses = articleIDs.map { ArticleStatus(articleID: $0, dateArrived: now) }
		cache.addObjectsNotCached(statuses)

		saveStatuses(Set(statuses), database)
	}

	// MARK: Utilities

	func articleIDsFromArticles(_ articles: Set<Article>) -> Set<String> {

		return Set(articles.map { $0.databaseID })
	}

	func articleIDsMissingCachedStatuses(_ articleIDs: Set<String>) -> Set<String> {
		
		return Set(articleIDs.filter { !cache.objectWithIDIsCached($0) })
	}

	func articlesMissingStatuses(_ articles: Set<Article>) -> Set<Article> {

		let missing = articles.flatMap { (article) -> Article? in
			if article.status == nil {
				return article
			}
			return nil
		}
		return Set(missing)
	}
}

//extension ParsedItem {
//
//	var articleID: String {
//		get {
//			return "\(feedURL) \(uniqueID)" //Must be same as Article.articleID
//		}
//	}
//}

