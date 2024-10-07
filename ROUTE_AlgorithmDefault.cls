public virtual without sharing class ROUTE_AlgorithmDefault {

	private List<UserObjectives> userObjectivesToProcess = new List<ROUTE_AlgorithmDefault.UserObjectives>();

	public List<UserComparabilityCell> userComparabilityCells {
		get {
			//Get accessor code block
			return userComparabilityCells;
		}
		set {
			if (UtilityList.isEmpty(value)) return;

			this.userComparabilityCells = value;
			Map<Id, Map<String, Double>> comparabilityValueByTasksByUserId = new Map<Id, Map<String, Double>>();

			for (UserComparabilityCell userComparabilityCell : value) {
				if (!comparabilityValueByTasksByUserId.containsKey(userComparabilityCell.userId))
					comparabilityValueByTasksByUserId.put(userComparabilityCell.userId, new Map<String, Double>{
						userComparabilityCell.objectiveId => userComparabilityCell.comparability
					});
				else comparabilityValueByTasksByUserId.get(userComparabilityCell.userId).put(userComparabilityCell.objectiveId, userComparabilityCell.comparability);
			}

			for (Id userId : comparabilityValueByTasksByUserId.keySet()) {
				UserObjectives userObjective = new UserObjectives();

				userObjective.userId = userId;
				userObjective.comparabilityByObjectiveId = comparabilityValueByTasksByUserId.get(userId);

				this.userObjectivesToProcess.add(userObjective);
			}


		}
	}


	public ROUTE_AlgorithmDefault() {
	}


	/**
	 * @param configPriorities Sorted by Priority List of User_Config_Priority__c
	 */
	public virtual void prioritizeCells(List<User_Config_Priority__c> configPriorities) {
		System.debug('PRIOR CELLS:' + configPriorities);

		List<UserObjectives> prioritizedUserObjectives = new List<UserObjectives>();

		for (User_Config_Priority__c userConfigPriority : configPriorities) {
			Id priorityUserId = userConfigPriority.User__c;

			for (UserObjectives userObjective : this.userObjectivesToProcess) {
				if (userObjective.userId == priorityUserId) {
					prioritizedUserObjectives.add(userObjective);
					continue;
				}
			}
		}

		this.userObjectivesToProcess = prioritizedUserObjectives;

		System.debug('PRIOR USER CELLS: ' + JSON.serializePretty(this.userObjectivesToProcess));
	}

	public class UserObjectives {
		public String userId = '';
		public Map<String, Double> comparabilityByObjectiveId = new Map<String, Double>();
		public Map<String, Double> suitableObjectives = new Map<String, Double>();
		public Set<String> routedObjectives = new Set<String>();

	}

	public virtual List<UserObjectives> route() {
		if (UtilityList.isEmpty(this.userObjectivesToProcess)) return new List<UserObjectives>();

		List<UserObjectives> userObjectivesPairMinimum = fillPairMinMatrix(this.userObjectivesToProcess);

		System.debug('PAI MIN: ' + JSON.serializePretty(userObjectivesPairMinimum));

		Map<String, Double> maxByObjectiveId = maxComparabilityByObjectId(userObjectivesPairMinimum);

		if (maxByObjectiveId == null || maxByObjectiveId.isEmpty()) return new List<UserObjectives>();
		System.debug('MAX BY ID: ' + maxByObjectiveId + ' : ' + maxByObjectiveId.values());

		Double minOfMaxComparability = UtilityMath.getMin(maxByObjectiveId.values());

		System.debug('Min of Max:' + minOfMaxComparability);

		if (minOfMaxComparability == null) return new List<UserObjectives>();

		Double closestUnder = findClosestUnder(minOfMaxComparability, this.userObjectivesToProcess);

		System.debug('CLOSES UNDER: ' + closestUnder);

		Set<String> nonRoutedObjectives = findOutSuitableObjectivesForUsersAndReturnUnMatched(this.userObjectivesToProcess, closestUnder);

		findBestObjectives(this.userObjectivesToProcess);
		System.debug('this.userObjectivesToProcess: ' + JSON.serializePretty(this.userObjectivesToProcess));
		System.debug('non routed: ' + nonRoutedObjectives);

		if (UtilityList.isNotEmpty(nonRoutedObjectives)) assignNonDesiredObjectivesToFirstOnes(nonRoutedObjectives, this.userObjectivesToProcess);

		return userObjectivesToProcess;
	}

	private static void assignNonDesiredObjectivesToFirstOnes(Set<String> nonRoutedObjectives, List<UserObjectives> objectivesToProcess) {
		Map<String, Set<String>> routedObjectivesByUserId = new Map<String, Set<String>>();

		for (String objectiveId : nonRoutedObjectives) {
			Double maxComparability = 0;
			String maxComparabilityUser = null;

			for (UserObjectives userObjective : objectivesToProcess) {
				Double comparability = userObjective.comparabilityByObjectiveId.get(objectiveId);

				if (comparability != null && comparability > maxComparability) {
					maxComparability = comparability;
					maxComparabilityUser = userObjective.userId;
				}
			}

			if (maxComparabilityUser != null) {
				if (!routedObjectivesByUserId.containsKey(maxComparabilityUser))
					routedObjectivesByUserId.put(maxComparabilityUser, new Set<String>{
						objectiveId
					});
				else routedObjectivesByUserId.get(maxComparabilityUser).add(objectiveId);
			}
		}

		for (UserObjectives userObjective : objectivesToProcess) {
			if (!routedObjectivesByUserId.containsKey(userObjective.userId)) continue;

			userObjective.routedObjectives.addAll(routedObjectivesByUserId.get(userObjective.userId));
		}

	}
	private static void findBestObjectives(List<UserObjectives> objectivesToProcess) {
		Set<String> routedObjectiveIds = new Set<String>();
		Set<String> allObjectivesToRoutes = new Set<String>();

		for (UserObjectives userObjective : objectivesToProcess) {
			allObjectivesToRoutes.addAll(userObjective.suitableObjectives.keySet());
			routedObjectiveIds.addAll(userObjective.routedObjectives);
		}

		for (UserObjectives userObjective : objectivesToProcess) {
			if (userObjective.suitableObjectives == null || userObjective.suitableObjectives.isEmpty()) continue;

			Double bestSuitableComparability = 0;
			String bestSuitableObjectiveId = null;

			for (String suitableObjectiveId : userObjective.suitableObjectives.keySet()) {
				Double suitableObjectiveComparability = userObjective.suitableObjectives.get(suitableObjectiveId);

				if (suitableObjectiveComparability > bestSuitableComparability && !routedObjectiveIds.contains(suitableObjectiveId)) {
					bestSuitableComparability = suitableObjectiveComparability;
					bestSuitableObjectiveId = suitableObjectiveId;
				}
			}

			if (bestSuitableObjectiveId != null) {
				routedObjectiveIds.add(bestSuitableObjectiveId);
				userObjective.routedObjectives.add(bestSuitableObjectiveId);
			}
		}

		if (routedObjectiveIds.size() != allObjectivesToRoutes.size()) findBestObjectives(objectivesToProcess);
	}
	private static Set<String> findOutSuitableObjectivesForUsersAndReturnUnMatched(List<UserObjectives> userObjectivesToProcess, Double closestSuitable) {
		Set<String> routedObjectiveIds = new Set<String>();
		Set<String> nonDesiredObjectiveIds = new Set<String>();

		for (UserObjectives userObjectives : userObjectivesToProcess) {
			nonDesiredObjectiveIds.addAll(userObjectives.comparabilityByObjectiveId.keySet());

			for (String objectiveId : userObjectives.comparabilityByObjectiveId.keySet()) {
				Double comparabilityValue = userObjectives.comparabilityByObjectiveId.get(objectiveId);

				if (comparabilityValue >= closestSuitable) {
					userObjectives.suitableObjectives.put(objectiveId, comparabilityValue);
					routedObjectiveIds.add(objectiveId);
				}
			}
		}

		nonDesiredObjectiveIds.removeAll(routedObjectiveIds);

		return nonDesiredObjectiveIds;
	}


	private static Double findClosestUnder(Double minValue, List<UserObjectives> userObjectivesToProcess) {
		if (minValue == null || minValue < 0 || UtilityList.isEmpty(userObjectivesToProcess)) return null;

		Double closest = 0;

		for (UserObjectives userObjective : userObjectivesToProcess) {
			for (Double comparability : userObjective.comparabilityByObjectiveId.values()) {
				if (comparability < minValue && comparability >= closest) closest = comparability;
			}
		}

		return closest == 0 ? minValue : closest;
	}
	private static Map<String, Double> maxComparabilityByObjectId(List<UserObjectives> pairMin) {
		if (UtilityList.isEmpty(pairMin)) return new Map<String, Double>();

		Map<String, Double> maxByObjectiveId = new Map<String, Double>();

		for (UserObjectives userObjective : pairMin) {
			for (String objectiveId : userObjective.comparabilityByObjectiveId.keySet()) {
				Double currentComparabilityValue = userObjective.comparabilityByObjectiveId.get(objectiveId);
				Double maxComparabilityValue = maxByObjectiveId.get(objectiveId);

				if (maxComparabilityValue == null) {
					maxByObjectiveId.put(objectiveId, currentComparabilityValue);
				} else if (maxComparabilityValue < currentComparabilityValue) {
					maxByObjectiveId.put(objectiveId, currentComparabilityValue);
				}
			}
		}

		return maxByObjectiveId;
	}

	private static List<UserObjectives> fillPairMinMatrix(List<UserObjectives> userObjectives) {
		List<UserObjectives> userObjectivesPairMinimum = new List<UserObjectives>();

		for (UserObjectives userObjective : userObjectives) {
			UserObjectives userObjectiveWithPairMin = new UserObjectives();
			List<String> objectiveIds = new List<String>(userObjective.comparabilityByObjectiveId.keySet());

			System.debug('OBJ IDS:' + objectiveIds);

			Integer objectivesSize = objectiveIds.size();

			if (objectivesSize == 1) {
				userObjectiveWithPairMin.comparabilityByObjectiveId.putAll(userObjective.comparabilityByObjectiveId);
				userObjectivesPairMinimum.add(userObjectiveWithPairMin);
				continue;
			}

			for (Integer objectiveIndex = 0; objectiveIndex < objectivesSize; objectiveIndex++) {
				Double leftObjectiveComparability = userObjective.comparabilityByObjectiveId.get(objectiveIds[objectiveIndex]);
				Double rightObjectiveComparability = 0;

				if (objectiveIndex == objectivesSize - 1) {
					Integer previousIndex = objectiveIndex - 1;
					rightObjectiveComparability = userObjective.comparabilityByObjectiveId.get(objectiveIds[previousIndex]);
				} else {
					Integer nextIndex = objectiveIndex + 1;
					rightObjectiveComparability = userObjective.comparabilityByObjectiveId.get(objectiveIds[nextIndex]);
				}

				userObjectiveWithPairMin.comparabilityByObjectiveId.put(objectiveIds[objectiveIndex], Math.min(leftObjectiveComparability, rightObjectiveComparability));
			}

			userObjectiveWithPairMin.userId = userObjective.userId;
			userObjectivesPairMinimum.add(userObjectiveWithPairMin);
		}

		return userObjectivesPairMinimum;
	}


}