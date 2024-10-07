public without sharing class RoutingService {
	public static final Boolean DEBUG = true;
	public static final Integer MAX_CONFIGS_IN_TRANSACTION = 90;


	public class RoutingServiceException extends Exception {
	}


	/**
	 * @description Route provided list of Objectives.
	 * @param objectivesToRoute
	 */
	public static List<ROUTE_AlgorithmDefault.UserObjectives> route(List<Objective__c> objectivesToRoute) {
		if (UtilityList.isEmpty(objectivesToRoute)) return new List<ROUTE_AlgorithmDefault.UserObjectives>();


		//Collect information for Routing
		Map<Id, Objective__c> objectiveById = new Map<Id, Objective__c>(objectivesToRoute);
		Set<String> objectiveConfigIds = UtilityList.extractStringValues(objectivesToRoute, Objective__c.Automation_Config__c.getDescribe().getName());
		List<Required_Skill_Position__c> requiredSkillPositions = RequiredSkillPositionManager.getByObjectiveIds(objectiveById.keySet());
		List<Expert_Estimate__c> expertEstimations = ExpertEstimateManager.getByObjectives(objectiveById.keySet());
		Map<String, List<Required_Skill_Position__c>> requiredSkillPositionByObjectiveId = getRequiredSkillPositionsByObjectiveId(requiredSkillPositions);
		Map<String, List<Expert_Estimate__c>> expertEstimateByObjectiveId = getExpertEstimatesByObjectiveId(expertEstimations);
		Map<Id, Routing_Algorithm__c> usedAlgorithmsById = extractRoutingAlgorithmsById(objectivesToRoute);
		Map<String, ExpertEstimateInfo> expertEstimateInfoByObjectiveId = buildExpertEstimateByObjectiveId(objectivesToRoute, expertEstimateByObjectiveId);
		Set<String> expertEstimateSkillPositionsInRouting = buildExpertEstimateSkillPositionsInRouting(expertEstimateInfoByObjectiveId.values());

		//Calculate suitable users
		Map<String, Set<Id>> suitableUsersByObjectiveId = calculateSuitableUsersByObjectiveId(
			objectiveById,
			requiredSkillPositionByObjectiveId,
			expertEstimateInfoByObjectiveId
		);
		Set<Id> usersInRouting = getSuitableUserIds(suitableUsersByObjectiveId);

		//Collect user Preferences and Priorities
		UserPreferenceCollection userPreferenceCollection = new UserPreferenceCollection(UserPreferenceManager.getByAssignedUserIdsAndSkillPositions(usersInRouting, expertEstimateSkillPositionsInRouting));
		Map<Id, List<User_Config_Priority__c>> configPrioritiesByAlgorithm = UserConfigPriorityManager.getByRoutingAlgorithmSortedByPriority(
			UserConfigPriorityManager.getManyToManyRoutingByUserIdAndConfigId(
				usersInRouting, objectiveConfigIds
			)
		);

		//Info for Matrix T by Algorithm
		Map<String, List<UserComparabilityCell>> userComparabilityCellsByAlgorithm = calculateUserComparabilityCellByAlgorithm(
			objectiveById,
			expertEstimateInfoByObjectiveId,
			suitableUsersByObjectiveId,
			userPreferenceCollection
		);

		System.debug('CELLS BY ALG: ' + userComparabilityCellsByAlgorithm);

		//Route User Objectives by Algorithm
		List<ROUTE_AlgorithmDefault.UserObjectives> routedUserObjectives = routeUserObjectives(
			userComparabilityCellsByAlgorithm,
			usedAlgorithmsById,
			configPrioritiesByAlgorithm
		);

		return routedUserObjectives;
	}

	public static void routeAndProcess(List<Objective__c> objectivesToRoute) {
		if (UtilityList.isEmpty(objectivesToRoute)) return;

		List<ROUTE_AlgorithmDefault.UserObjectives> routedUserObjectives = route(objectivesToRoute);
		//Update Objectives with Routes Users.
		if (!routedUserObjectives.isEmpty()) {
			processRoutedUserObjectives(routedUserObjectives, new Map<Id, Objective__c>(objectivesToRoute));
		}
	}

	/**
	 * @description Calculates best user for Objective and return it Id.
	 * @param objectiveToRoute
	 *
	 * @return
	 */
	public static UserComparabilityCell route(Objective__c objectiveToRoute) {
		if (objectiveToRoute == null) return null;

		List<Required_Skill_Position__c> requiredSkillPositions = RequiredSkillPositionManager.getByObjectiveId(objectiveToRoute.Id);
		List<Expert_Estimate__c> expertEstimations = ExpertEstimateManager.getByObjective(objectiveToRoute.Id);

		if (UtilityList.isEmpty(requiredSkillPositions) && UtilityList.isEmpty(expertEstimations)) {
			System.debug('No conditions specified, not possible to define the User to rout to!!');
			return null;
		}

		ExpertEstimateInfo expertEstimateInfo = new ExpertEstimateInfo(expertEstimations);
		Set<Id> suitableUsersByRequiredSkillPositions = calculateSuitableUsersByRequiredSkillPositions(
			UtilityList.extractStringValues(requiredSkillPositions, 'Skill_Position__c')
		);

		if (suitableUsersByRequiredSkillPositions.isEmpty()) return null;

		List<User_Preference__c> userPreferences = UserPreferenceManager.getByAssignedUserIdsAndSkillPositions(suitableUsersByRequiredSkillPositions, expertEstimateInfo.expertEstimatesSkillPositionIds);
		Map<Id, User_Config_Priority__c> priorityByUserId = UserConfigPriorityManager.getById(
			UserConfigPriorityManager.getSingleRoutingByUserIdAndConfigId(suitableUsersByRequiredSkillPositions, objectiveToRoute.Automation_Config__c)
		);

		Map<String, Map<String, Double>> maximumBySkillByUser = buildMaximumBySkillByUser(expertEstimateInfo, userPreferences);
		Map<Double, Set<Id>> userIdsByComparabilityValue = calculateUserIdsByComparabilityValueForSingleRoute(maximumBySkillByUser, expertEstimateInfo, priorityByUserId);
		Double maxComparabilityOfAllUsers = UtilityMath.getMax(new List<Double>(userIdsByComparabilityValue.keySet()));

		System.debug('MAX COMPARABILITY : ' + JSON.serializePretty(maxComparabilityOfAllUsers));

		return new UserComparabilityCell(
			objectiveToRoute.Id,
			userIdsByComparabilityValue.get(maxComparabilityOfAllUsers).iterator().next(),
			maxComparabilityOfAllUsers
		);
	}


	/**
	 * @description Extract all suitable users from provided map
	 * @param suitableUsersByObjectiveId
	 *
	 * @return
	 */
	private static Set<Id> getSuitableUserIds(Map<String, Set<Id>> suitableUsersByObjectiveId) {
		if (suitableUsersByObjectiveId == null || suitableUsersByObjectiveId.isEmpty()) return new Set<Id>();

		Set<Id> usersInRouting = new Set<Id>();

		for (Set<Id> suitableUsers : suitableUsersByObjectiveId.values()) {
			if (UtilityList.isEmpty(suitableUsers)) continue;
			usersInRouting.addAll(suitableUsers);
		}

		return usersInRouting;
	}

	/**
	 * @description Calculates suitable users for Objectives based on Required Skills
	 * @param objectiveById
	 * @param requiredSkillPositionByObjectiveId
	 * @param expertEstimateInfoByObjectiveId
	 *
	 * @return
	 */
	private static Map<String, Set<Id>> calculateSuitableUsersByObjectiveId(Map<Id, Objective__c> objectiveById, Map<String, List<Required_Skill_Position__c>> requiredSkillPositionByObjectiveId,
		Map<String, ExpertEstimateInfo> expertEstimateInfoByObjectiveId) {
		Map<String, Set<Id>> suitableUsersByObjectiveId = new Map<String, Set<Id>>();

		//Calculate suitable Users for Objectives.
		for (Id objectiveId : objectiveById.keySet()) {
			List<Required_Skill_Position__c> requiredSkillPositionsForObjective = requiredSkillPositionByObjectiveId.get(objectiveId) ?? new List<Required_Skill_Position__c>();

			Set<Id> suitableUsers = calculateSuitableUsersByRequiredSkillPositions(
				UtilityList.extractStringValues(requiredSkillPositionsForObjective, 'Skill_Position__c')
			);

			ExpertEstimateInfo expertEstimateInfo = expertEstimateInfoByObjectiveId.get(objectiveId);
			Boolean hasExpertEstimates = expertEstimateInfo != null && UtilityList.isNotEmpty(expertEstimateInfo.expertEstimatesSkillPositionIds);

			if (suitableUsers.isEmpty() && hasExpertEstimates) {
				Set<Id> suitableUserIdsByExpertEstimate = calculateSuitableUsersByExpertEstimates(expertEstimateInfo.expertEstimatesSkillPositionIds);

				if (UtilityList.isEmpty(suitableUserIdsByExpertEstimate))
					continue;
				else suitableUsers.addAll(suitableUserIdsByExpertEstimate);
			}

			suitableUsersByObjectiveId.put(objectiveId, suitableUsers);
		}

		return suitableUsersByObjectiveId;
	}

	/**
	 * @description Extracts all Expert Estimation Skill Positions
	 * @param expertEstimateInfos
	 *
	 * @return
	 */
	private static Set<String> buildExpertEstimateSkillPositionsInRouting(List<ExpertEstimateInfo> expertEstimateInfos) {
		if (UtilityList.isEmpty(expertEstimateInfos)) return new Set<String>();

		Set<String> expertEstimateSkillPositions = new Set<String>();

		for (ExpertEstimateInfo expertEstimateInfo : expertEstimateInfos) {
			if (UtilityList.isEmpty(expertEstimateInfo.expertEstimatesSkillPositionIds)) continue;

			expertEstimateSkillPositions.addAll(expertEstimateInfo.expertEstimatesSkillPositionIds);
		}

		return expertEstimateSkillPositions;
	}

	/**
	 * @description Builds a map {ObjectiveId: Related ExpertEstimateInfo}
	 * @param objectivesToProcess
	 * @param expertEstimateByObjectiveId
	 *
	 * @return
	 */
	private static Map<String, ExpertEstimateInfo> buildExpertEstimateByObjectiveId(List<Objective__c> objectivesToProcess, Map<String, List<Expert_Estimate__c>> expertEstimateByObjectiveId) {
		if (UtilityList.isEmpty(objectivesToProcess) || expertEstimateByObjectiveId == null || expertEstimateByObjectiveId.isEmpty()) return new Map<String, RoutingService.ExpertEstimateInfo>();

		Map<String, ExpertEstimateInfo> expertEstimateInfoByObjectiveId = new Map<String, RoutingService.ExpertEstimateInfo>();

		for (Objective__c objective : objectivesToProcess) {
			List<Expert_Estimate__c> expertEstimates = expertEstimateByObjectiveId.get(objective.Id);

			if (UtilityList.isEmpty(expertEstimates)) continue;

			expertEstimateInfoByObjectiveId.put(objective.Id, new ExpertEstimateInfo(expertEstimates));
		}

		return expertEstimateInfoByObjectiveId;
	}

	/**
	 * @description Route Users to the Objectives based on Algorithm
	 * @param userComparabilityCellsByAlgorithm
	 * @param algorithmsById
	 * @param configPrioritiesByAlgorithm
	 *
	 * @return
	 */
	private static List<ROUTE_AlgorithmDefault.UserObjectives> routeUserObjectives(Map<String, List<UserComparabilityCell>> userComparabilityCellsByAlgorithm,
		Map<Id, Routing_Algorithm__c> algorithmsById, Map<Id, List<User_Config_Priority__c>> configPrioritiesByAlgorithm) {
		List<ROUTE_AlgorithmDefault.UserObjectives> routedUserObjectives = new List<ROUTE_AlgorithmDefault.UserObjectives>();

		for (String algorithmId : userComparabilityCellsByAlgorithm.keySet()) {
			Routing_Algorithm__c algorithm = algorithmsById.get(algorithmId);

			ROUTE_AlgorithmDefault algorithmClass = (ROUTE_AlgorithmDefault) Type.forName(algorithm.Apex_Handler__c).newInstance();

			algorithmClass.userComparabilityCells = userComparabilityCellsByAlgorithm.get(algorithmId);
			algorithmClass.prioritizeCells(configPrioritiesByAlgorithm.get(algorithmId));

			routedUserObjectives.addAll(algorithmClass.route());
		}

		return routedUserObjectives;
	}

	/**
	 * @description Builds a map {Key - Algorithm.Id, Value:Routing_Algorithm__c}
	 * @param objectivesToProcess
	 *
	 * @return
	 */
	private static Map<Id, Routing_Algorithm__c> extractRoutingAlgorithmsById(List<Objective__c> objectivesToProcess) {
		if (UtilityList.isEmpty(objectivesToProcess)) return new Map<Id, Routing_Algorithm__c>();

		Map<Id, Routing_Algorithm__c> usedAlgorithmsById = new Map<Id, Routing_Algorithm__c>();

		for (Objective__c objective : objectivesToProcess) {
			usedAlgorithmsById.put(objective.Automation_Config__r.Routing_Algorithm__c, objective.Automation_Config__r.Routing_Algorithm__r);
		}

		return usedAlgorithmsById;
	}

	/**
	 * @description Calculates user Comparability to the Objectives.
	 * @param objectiveById
	 * @param expertEstimateInfoByObjectiveId
	 * @param suitableUsersByObjectiveId
	 * @param userPreferenceCollection
	 *
	 * @return
	 */
	private static Map<String, List<UserComparabilityCell>> calculateUserComparabilityCellByAlgorithm(Map<Id, Objective__c> objectiveById, Map<String, ExpertEstimateInfo> expertEstimateInfoByObjectiveId,
		Map<String, Set<Id>> suitableUsersByObjectiveId, UserPreferenceCollection userPreferenceCollection) {
		if (objectiveById == null || objectiveById.isEmpty()
			|| expertEstimateInfoByObjectiveId == null || expertEstimateInfoByObjectiveId.isEmpty()
			|| suitableUsersByObjectiveId == null || suitableUsersByObjectiveId.isEmpty()
			|| userPreferenceCollection.isEmpty())
			return new Map<String, List<UserComparabilityCell>>();

		Map<String, List<UserComparabilityCell>> userComparabilityCellsByAlgorithm = new Map<String, List<UserComparabilityCell>>();
		Map<Id, Routing_Algorithm__c> usedAlgorithmsById = new Map<Id, Routing_Algorithm__c>();

		for (Id objectiveId : objectiveById.keySet()) {
			ExpertEstimateInfo expertEstimateInfo = expertEstimateInfoByObjectiveId.get(objectiveId);
			Objective__c objective = objectiveById.get(objectiveId);
			Set<Id> suitableUsers = suitableUsersByObjectiveId.get(objectiveId);

			if (UtilityList.isEmpty(suitableUsers) || expertEstimateInfo == null) continue;

			Map<String, Map<String, Double>> maxTopBySkillIdByUserId = new Map<String, Map<String, Double>>();

			//Calculate TOP of the T Formula
			for (Id userId : suitableUsers) {
				Map<String, Double> maxTopBySkillId = new Map<String, Double>();

				for (Expert_Estimate__c expertEstimate : expertEstimateInfo.expertEstimations) {

					Double userPreference = userPreferenceCollection.get(userId, expertEstimate.Skill_Position__c)?.Preference_Value__c ?? 0;
					Double expertEstimateValue = expertEstimate.Expert_Value__c ?? 0 ;

					Double max = userPreference * expertEstimateValue;
					String skillId = expertEstimate.Skill_Position__r.Skill__c;

					//Move to Utility
					if (!maxTopBySkillId.containsKey(skillId)) {
						maxTopBySkillId.put(skillId, max);
					} else if (maxTopBySkillId.get(skillId) < max) {
						maxTopBySkillId.put(skillId, max);
					}

					maxTopBySkillIdByUserId.put(userId, maxTopBySkillId);
				}
			}

			for (Id userId : suitableUsers) {

				Double maxUserComparabilityForAllSkills = 0;
				Double expertEstimationForAllSkills = 0;

				for (String skillId : expertEstimateInfo.skillIds) {
					Double maxExpertEstimateForSkill = expertEstimateInfo.getMaxForSkill(skillId) ?? 0;

					expertEstimationForAllSkills += maxExpertEstimateForSkill;

					if (!maxTopBySkillIdByUserId.containsKey(userId)) continue;

					Double maxUserComparabilityForSkill = maxTopBySkillIdByUserId.get(userId).get(skillId) ?? 0;

					maxUserComparabilityForAllSkills += maxUserComparabilityForSkill;
				}

				if (expertEstimationForAllSkills == 0) continue;

				Double userObjectiveComparability = maxUserComparabilityForAllSkills / expertEstimationForAllSkills;

				//We do not support 0 as a comparability in T matrix
				if (userObjectiveComparability == 0) continue;

				UserComparabilityCell userComparabilityCell = new UserComparabilityCell(
					objectiveId, userId, userObjectiveComparability
				);

				if (!userComparabilityCellsByAlgorithm.containsKey(objective.Automation_Config__r.Routing_Algorithm__c)) {
					userComparabilityCellsByAlgorithm.put(objective.Automation_Config__r.Routing_Algorithm__c, new List<UserComparabilityCell>{
						userComparabilityCell
					});

					usedAlgorithmsById.put(objective.Automation_Config__r.Routing_Algorithm__c, objective.Automation_Config__r.Routing_Algorithm__r);
				} else {
					userComparabilityCellsByAlgorithm.get(objective.Automation_Config__r.Routing_Algorithm__c).add(userComparabilityCell);
				}

			}
		}

		return userComparabilityCellsByAlgorithm;
	}

	/**
	 * @description Assigns users to the routed objectives and completes the routing.
	 * @param routesUserObjectives
	 * @param objectiveById
	 */
	private static void processRoutedUserObjectives(List<ROUTE_AlgorithmDefault.UserObjectives> routesUserObjectives, Map<Id, Objective__c> objectiveById) {
		if (UtilityList.isEmpty(routesUserObjectives) || objectiveById == null || objectiveById.isEmpty()) return;

		List<Objective__c> objectivesToUpdate = new List<Objective__c>();

		for (ROUTE_AlgorithmDefault.UserObjectives userObjectives : routesUserObjectives) {
			if (UtilityList.isEmpty(userObjectives.routedObjectives)) continue;

			for (String objectiveId : userObjectives.routedObjectives) {

				objectivesToUpdate.add(
					new Objective__c(
						Id = objectiveId,
						Status__c = ObjectiveManager.STATUS_ROUTED,
						Assigned_User__c = userObjectives.userId,
						Used_Routing_Algorithm__c = objectiveById.get(objectiveId)?.Automation_Config__r.Routing_Algorithm__c,
						Assigned_Comparability__c = userObjectives.comparabilityByObjectiveId.get(objectiveId) * 100
					)
				);
			}
		}

		if (UtilityList.isNotEmpty(objectivesToUpdate)) update objectivesToUpdate;
	}


	/**
	 * @description Builds a map {Key - ObjectiveId, Value: Related List of Expert Estimates}
	 * @param expertEstimates
	 *
	 * @return
	 */
	private static Map<String, List<Expert_Estimate__c>> getExpertEstimatesByObjectiveId(List<Expert_Estimate__c> expertEstimates) {
		if (UtilityList.isEmpty(expertEstimates)) return new Map<String, List<Expert_Estimate__c>>();

		Map<String, List<Expert_Estimate__c>> estimateByObjectiveId = new Map<String, List<Expert_Estimate__c>>();

		for (Expert_Estimate__c expertEstimate : expertEstimates) {
			if (expertEstimate == null || expertEstimate.Id == null) continue;

			if (!estimateByObjectiveId.containsKey(expertEstimate.Related_Objective__c)) estimateByObjectiveId.put(expertEstimate.Related_Objective__c, new List<Expert_Estimate__c>{
				expertEstimate
			});
			else estimateByObjectiveId.get(expertEstimate.Related_Objective__c).add(expertEstimate);
		}

		return estimateByObjectiveId;
	}


	/**
	 * @description Builds a map {Key - ObjectiveId, Value: Related List of Required Skill Positions}
	 * @param requiredSkillPositions
	 *
	 * @return
	 */
	private static Map<String, List<Required_Skill_Position__c>> getRequiredSkillPositionsByObjectiveId(List<Required_Skill_Position__c> requiredSkillPositions) {
		if (UtilityList.isEmpty(requiredSkillPositions)) return new Map<String, List<Required_Skill_Position__c>>();

		Map<String, List<Required_Skill_Position__c>> requiredSkillPositionByObjectiveId = new Map<String, List<Required_Skill_Position__c>>();

		for (Required_Skill_Position__c requiredSkillPosition : requiredSkillPositions) {
			if (requiredSkillPosition == null || requiredSkillPosition.Id == null) continue;

			if (!requiredSkillPositionByObjectiveId.containsKey(requiredSkillPosition.Related_Objective__c))
				requiredSkillPositionByObjectiveId.put(requiredSkillPosition.Related_Objective__c, new List<Required_Skill_Position__c>{
					requiredSkillPosition
				});
			else requiredSkillPositionByObjectiveId.get(requiredSkillPosition.Related_Objective__c).add(requiredSkillPosition);
		}

		return requiredSkillPositionByObjectiveId;
	}

	/**
	 * @description Calculates comparability value for each User. Groups users by Comparability Value.
	 * @param maximumBySkillByUser
	 * @param expertEstimateInfo
	 * @param priorityByUserId
	 *
	 * @return
	 */
	private static Map<Double, Set<Id>> calculateUserIdsByComparabilityValueForSingleRoute(Map<String, Map<String, Double>> maximumBySkillByUser, ExpertEstimateInfo expertEstimateInfo, Map<Id, User_Config_Priority__c> priorityByUserId) {
		Map<Double, Set<Id>> userIdsByComparabilityValue = new Map<Double, Set<Id>>();

		for (String userId : maximumBySkillByUser.keySet()) {
			Map<String, Double> maxBySkill = maximumBySkillByUser.get(userId);

			List<Double> expertMaxForSkills = new List<Double>();
			List<Double> userComparabilityMaxForSkills = new List<Double>();

			for (String skillId : expertEstimateInfo.maxExpertEstimateBySkill.keySet()) {
				Double expertMaximum = expertEstimateInfo.maxExpertEstimateBySkill.get(skillId);
				Double userSkillComparabilityMax = maxBySkill.get(skillId) ?? 0;

				expertMaxForSkills.add(expertMaximum);
				userComparabilityMaxForSkills.add(userSkillComparabilityMax);
			}

			Double expertSum = UtilityMath.sum(expertMaxForSkills);
			Double userComparabilitySum = UtilityMath.sum(userComparabilityMaxForSkills);
			Double comparability = 0;

			if (expertSum != 0) {
				comparability = userComparabilitySum / expertSum;
			}

			Double userPriorityWeight = priorityByUserId.get(userId)?.Priority__c ?? 1;
			Double userComparability = comparability * userPriorityWeight;
			System.debug('\n\t' + userId + ' \n\tComparability = (' + userComparabilitySum + ' / ' + expertSum + ') * ' + userPriorityWeight + '  = ' + userComparability);

			if (!userIdsByComparabilityValue.containsKey(userComparability)) {
				userIdsByComparabilityValue.put(userComparability, new Set<Id>{
					userId
				});
			} else {
				userIdsByComparabilityValue.get(userComparability).add(userId);
			}
		}

		return userIdsByComparabilityValue;
	}

	/**
	 * @description Calculates comparability value for each User. Groups users by Comparability Value.
	 * @param maximumBySkillByUser
	 * @param expertEstimateInfo
	 * @param priorityByUserId
	 *
	 * @return
	 */
	private static Map<Double, Set<Id>> calculateUserIdsByComparabilityValueForMultiRoute(Map<String, Map<String, Double>> maximumBySkillByUser, ExpertEstimateInfo expertEstimateInfo) {
		Map<Double, Set<Id>> userIdsByComparabilityValue = new Map<Double, Set<Id>>();

		for (String userId : maximumBySkillByUser.keySet()) {
			Map<String, Double> maxBySkill = maximumBySkillByUser.get(userId);

			List<Double> expertMaxForSkills = new List<Double>();
			List<Double> userComparabilityMaxForSkills = new List<Double>();

			for (String skillId : expertEstimateInfo.maxExpertEstimateBySkill.keySet()) {
				Double expertMaximum = expertEstimateInfo.maxExpertEstimateBySkill.get(skillId);
				Double userSkillComparabilityMax = maxBySkill.get(skillId) ?? 0;

				expertMaxForSkills.add(expertMaximum);
				userComparabilityMaxForSkills.add(userSkillComparabilityMax);
			}

			Double expertSum = UtilityMath.sum(expertMaxForSkills);
			Double userComparabilitySum = UtilityMath.sum(userComparabilityMaxForSkills);
			Double comparability = 0;

			if (expertSum != 0) {
				comparability = userComparabilitySum / expertSum;
			}

			Double userComparability = comparability;
			System.debug('\n\t' + userId + ' \n\tComparability = (' + userComparabilitySum + ' / ' + expertSum + ')' + '  = ' + userComparability);

			if (!userIdsByComparabilityValue.containsKey(userComparability)) {
				userIdsByComparabilityValue.put(userComparability, new Set<Id>{
					userId
				});
			} else {
				userIdsByComparabilityValue.get(userComparability).add(userId);
			}
		}

		return userIdsByComparabilityValue;
	}


	/**
	 * @description Calculates Maximum Preference for each Skill by each User
	 * @param expertEstimateInfo
	 * @param userPreferences
	 *
	 * @return
	 */
	private static Map<String, Map<String, Double>> buildMaximumBySkillByUser(ExpertEstimateInfo expertEstimateInfo, List<User_Preference__c> userPreferences) {
		Map<String, Map<String, Double>> maximumBySkillByUser = new Map<String, Map<String, Double>>();

		//Build maximumBySkillByUser
		for (User_Preference__c userPreference : userPreferences) {
			Map<String, Double> maxBySkill = maximumBySkillByUser.get(userPreference.Assigned_User__c);

			if (maxBySkill == null) maxBySkill = new Map<String, Double>();

			Expert_Estimate__c expertEstimate = expertEstimateInfo.expertEstimateBySkillPosition.get(userPreference.Skill_Position__c);
			Double expertEstimateValue = expertEstimate == null ? 0 : expertEstimate.Expert_Value__c;

			Double userSkillPositionComparability = userPreference.Preference_Value__c * expertEstimateValue;

			//Put maximum comparability to maxBySkill
			if (!maxBySkill.containsKey(userPreference.Skill_Position__r.Skill__c))
				maxBySkill.put(userPreference.Skill_Position__r.Skill__c, userSkillPositionComparability);
			else if (maxBySkill.get(userPreference.Skill_Position__r.Skill__c) < userSkillPositionComparability)
				maxBySkill.put(userPreference.Skill_Position__r.Skill__c, userSkillPositionComparability);

			maximumBySkillByUser.put(userPreference.Assigned_User__c, maxBySkill);
		}

		return maximumBySkillByUser;
	}


	/**
	 * @description  Return all the Users with all provided Required Skill Positions
	 * @param requiredSkillPositionPositionIds
	 *
	 * @return
	 */
	private static Set<Id> calculateSuitableUsersByRequiredSkillPositions(Set<String> requiredSkillPositionPositionIds) {
		if (UtilityList.isEmpty(requiredSkillPositionPositionIds)) {
			return new Set<Id>();
		}

		List<AggregateResult> filteredUsersByRequiredSkillPositions = [
			SELECT Assigned_User__c UserId
			FROM User_Preference__c
			WHERE Preference_Value__c > 0
				AND Skill_Position__c IN :requiredSkillPositionPositionIds
			GROUP BY Assigned_User__c
			HAVING COUNT(Assigned_User__c) = :requiredSkillPositionPositionIds.size()
		];

		System.debug('Results SOQL: ' + JSON.serializePretty(filteredUsersByRequiredSkillPositions));

		if (filteredUsersByRequiredSkillPositions.isEmpty()) return new Set<Id>();

		return extractSuitableUserIds(filteredUsersByRequiredSkillPositions);
	}

	/**
	 * @description Returns suitable Users by expert estimates. Use only when Required skill are not defined.
	 * @param expertEstimatesSkillPositionIds
	 *
	 * @return
	 */
	private static Set<Id> calculateSuitableUsersByExpertEstimates(Set<String> expertEstimatesSkillPositionIds) {
		if (UtilityList.isEmpty(expertEstimatesSkillPositionIds)) {
			List<User> firstUsers = [SELECT Id FROM User LIMIT 1];

			return firstUsers.isEmpty() ? new Set<Id>() : new Set<Id>{
				firstUsers[0].Id
			};
		}

		List<AggregateResult> filteredUsersByExpertEstimateSkillPositions = [
			SELECT Assigned_User__c UserId
			FROM User_Preference__c
			WHERE Preference_Value__c > 0
				AND Skill_Position__c IN :expertEstimatesSkillPositionIds
			GROUP BY Assigned_User__c
		];

		System.debug('Results SOQL: ' + JSON.serializePretty(filteredUsersByExpertEstimateSkillPositions));

		if (filteredUsersByExpertEstimateSkillPositions.isEmpty()) return null;

		return extractSuitableUserIds(filteredUsersByExpertEstimateSkillPositions);
	}

	/**
	 * @description Extracts UsersIds from AggregateResult
	 * @param filteredUsersByRequiredSkillPositions
	 *
	 * @return
	 */
	private static Set<Id> extractSuitableUserIds(List<AggregateResult> filteredUsersByRequiredSkillPositions) {
		if (UtilityList.isEmpty(filteredUsersByRequiredSkillPositions)) return new Set<Id>();

		Set<Id> suitableUsersByRequiredSkillPositions = new Set<Id>();

		for (AggregateResult filterResult : filteredUsersByRequiredSkillPositions) {
			if (filterResult.get('UserId') == null) continue;

			suitableUsersByRequiredSkillPositions.add(String.valueOf(filterResult.get('UserId')));
		}


		return suitableUsersByRequiredSkillPositions;
	}


	private class ExpertEstimateInfo {
		public Map<String, Double> maxExpertEstimateBySkill = new Map<String, Double>();
		public Map<String, Double> sumExpertEstimateBySkill = new Map<String, Double>();
		public Map<String, Expert_Estimate__c> expertEstimateBySkillPosition = new Map<String, Expert_Estimate__c>();
		public List<Expert_Estimate__c> expertEstimations = new List<Expert_Estimate__c>();
		public Set<String> expertEstimatesSkillPositionIds = new Set<String>();
		public Set<String> skillIds = new Set<String>();

		public ExpertEstimateInfo(List<Expert_Estimate__c> expertEstimations) {
			if (UtilityList.isEmpty(expertEstimations)) return;

			this.expertEstimations = expertEstimations;
			this.expertEstimatesSkillPositionIds = UtilityList.extractStringValues(expertEstimations, 'Skill_Position__c');

			for (Expert_Estimate__c expertEstimate : expertEstimations) {
				this.expertEstimateBySkillPosition.put(expertEstimate.Skill_Position__c, expertEstimate);

				this.skillIds.add(expertEstimate.Skill_Position__r.Skill__c);
				this.processMax(expertEstimate);
				this.processSum(expertEstimate);
			}
		}


		private Double getMaxForSkill(String skillId) {
			return this.maxExpertEstimateBySkill.get(skillId);
		}

		private Double getSumForSkill(String skillId) {
			return this.sumExpertEstimateBySkill.get(skillId);
		}

		private void processMax(Expert_Estimate__c expertEstimate) {
			if (!this.maxExpertEstimateBySkill.containsKey(expertEstimate.Skill_Position__r.Skill__c)) {
				this.maxExpertEstimateBySkill.put(expertEstimate.Skill_Position__r.Skill__c, expertEstimate.Expert_Value__c);
			} else if (this.maxExpertEstimateBySkill.get(expertEstimate.Skill_Position__r.Skill__c) < expertEstimate.Expert_Value__c) {
				this.maxExpertEstimateBySkill.put(expertEstimate.Skill_Position__r.Skill__c, expertEstimate.Expert_Value__c);
			}
		}

		private void processSum(Expert_Estimate__c expertEstimate) {
			if (!this.sumExpertEstimateBySkill.containsKey(expertEstimate.Skill_Position__r.Skill__c)) {
				this.sumExpertEstimateBySkill.put(expertEstimate.Skill_Position__r.Skill__c, expertEstimate.Expert_Value__c);
			} else {
				this.sumExpertEstimateBySkill.put(expertEstimate.Skill_Position__r.Skill__c, this.sumExpertEstimateBySkill.get(expertEstimate.Skill_Position__r.Skill__c) + +expertEstimate.Expert_Value__c);
			}
		}
	}

}